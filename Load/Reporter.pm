# Schedule::Load::Reporter.pm -- distributed lock handler
# $Id: Reporter.pm,v 1.43 2003/05/21 17:45:04 wsnyder Exp $
######################################################################
#
# This program is Copyright 2002 by Wilson Snyder.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of either the GNU General Public License or the
# Perl Artistic License.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# If you do not have a copy of the GNU General Public License write to
# the Free Software Foundation, Inc., 675 Mass Ave, Cambridge, 
# MA 02139, USA.
######################################################################

package Schedule::Load::Reporter;
require 5.004;
require Exporter;
@ISA = qw(Exporter);

use Socket;
use IO::Socket;
use IO::Select;
use POSIX;

use Proc::ProcessTable;
use Unix::Processors;
use Storable qw (nstore retrieve);
use Schedule::Load qw (:_utils);
use Schedule::Load::FakeReporter;
use Sys::Hostname;
use Time::HiRes qw (gettimeofday);
use IPC::PidStat;
use Config;

use strict;
use vars qw($VERSION $Debug %User_Names %Pid_Inherit 
	    @Pid_Time_Base @Pid_Time $Os_Linux
	    $Distrust_Pctcpu $Divide_Pctcpu_By_Cpu
	    $Exister
	    );
use Carp;

######################################################################
#### Configuration Section

# Other configurable settings.
$Debug = $Schedule::Load::Debug;

$VERSION = '3.001';

$Os_Linux = $Config{osname} =~ /linux/i;
$Distrust_Pctcpu = $Config{osname} !~ /solaris/i;	# Only solaris has instantanous reporting
$Divide_Pctcpu_By_Cpu = 0;   # Older linuxes may require this

######################################################################
#### Globals

# This is the self elemenst sent over the socket:
# $self->{const}{config_element_name} = value	# Such as things from ENV
# $self->{load}{load_element} = value		# Overall loading info
# $self->{proc}{process#}{proc_element} = value	# Per process info

# Cache of user name based on UID
%User_Names = ();

# Cache of fixed loads based on PID
%Pid_Inherit = ();

######################################################################
#### Creator

sub start {
    # Establish the reporter
    @_ >= 1 or croak 'usage: Schedule::Load::Reporter->start ({options})';
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = {
	%Schedule::Load::_Default_Params,
	#Documented
	#Undocumented
	timeout=>$Debug?2:30,		# Sec before host socket connect times out
	alive_time=>$Debug?10:30,	# Sec to send alive message
	const_changed=>0,		# const or stored has changed, update in chooser
	@_};
    bless $self, $class;

    # More defaults (can't be above due to needing other elements)
    $self->{const}{hostname} ||= hostname();
    $self->{const}{slreportd_hostname} ||= hostname();
    $self->{stored_filename} ||= ("/usr/local/lib/rschedule/slreportd_".$self->{const}{hostname}."_store");

    (defined $self->{dhost}) or croak 'Require a host parameter';
    #foreach (@{$self->{dhost}}) { print "Host $_\n"; }

    my $select = IO::Select->new();

    $Exister = new IPC::PidStat();
    $select->add($Exister->fh);

    $self->pt();	# Create process table
    $self->fake_pt();	# Create process table

    # Load constants
    $self->_fill_const;
    $self->_fill_stored;
    $self->_fill_dynamic;

    while (1) {
	# See if alive
	if ($self->{socket}) {
	    _alive_check ($self);
	}

	if (! $self->{socket}) {
	    # Open the socket to first found host
	    foreach my $host (@{$self->{dhost}}) {
		last if ($self->_open_host($host));
	    }
	    $select->remove($select->handles);
	    $select->add($Exister->fh);
	    $select->add($self->{socket}) if $self->{socket};
	}

	# Wait for someone to become active
	# or send a alive message every 60 secs (in case slchoosed goes down & up)
	sleep($self->{alive_time}) if ($select->count() == 0); # select won't block if no fd's
	my $inbuffer = '';
      input:
	foreach my $fh ($select->can_read ($self->{alive_time})) {
	    print "Servicing input\n" if $Debug;
	    if ($fh == $Exister->fh) {
		_exist_traffic();
	    }
	    else {
		# Snarf input
		if ($inbuffer !~ /\n/) {
		    my $data='';
		    my $rv = $fh->sysread($data, POSIX::BUFSIZ);
		    if (!defined $rv || (length $data == 0)) {
			next input;
		    }
		    $inbuffer .= $data;
		}

		while ($inbuffer =~ s/(.*?)\n//) {
		    my $line = $1;
		    chomp $line;
		    print "REQ $line\n" if $Debug;
		    my ($cmd, $params) = _pthaw($line, $Debug);
		    # Commands
		    if ($cmd eq "report_get_dynamic") {
			$self->_fill_and_send;
		    } elsif ($cmd eq "report_fwd_set") {
			$self->_set_stored($params);
		    } elsif ($cmd eq "report_fwd_comment") {
			$self->_comment($params);
		    } elsif ($cmd eq "report_fwd_fixed_load") {
			$self->_fixed_load($params);
		    } elsif ($cmd eq "report_restart") {
			# Overall fork loop will deal with it.
			warn "-Info: report_restart\n" if $Debug;
			exit(0);
		    } else {
			warn "%Error: Bad request from server: $line\n" if $Debug;
		    }
		}
	    }
	}
    }
}

######################################################################
######################################################################
#### Accessors

sub pt {
    my $self = shift;
    if (!$self->{pt}) {
	$self->{pt} = new Proc::ProcessTable( 'cache_ttys' => 1 ); 
    }
    return $self->{pt};
}

sub fake_pt {
    my $self = shift;
    if (!$self->{fake_pt}) {
	$self->{fake_pt} = Schedule::Load::FakeReporter::ProcessTable
	    ->new (reportref=>$self);
    }
    return $self->{fake_pt};
}

######################################################################
######################################################################
#### Sending

sub _open_host {
    my $self = shift;
    my $host = shift;
    # Open a socket to the given host return true if successful

    print "Trying host $host $self->{port}\n" if $Debug;
    my $fh = Schedule::Load::Socket->new(
					 PeerAddr  => $host,
					 PeerPort  => $self->{port},
					 Timeout   => $self->{timeout},
				         );
    $self->{socket} = $fh;
    $self->{socket} = undef if (!$fh || !$fh->connected());
    if ($self->{socket}) {
	# Send constants to the host, that will tell it we live
	$self->{stored_read} = 0;   # Reread stored info in case redundant reporters
	$self->{const_changed} = 1;
	$self->{const}{_update} = 0;
	$self->_fill_and_send;
	$self->{const}{_update} = 1;   # So chooser can skip calling start function
    }
    print "   Host $host $self->{port} is ".($self->{socket}?"up":"down")."!\n" if $Debug;
    return $self->{socket};
}

sub _alive_check {
    my $self = shift;
    my $msg = "report_ping\n";
    # Send a line to the socket to see if all is well
    my $fh = $self->{socket};
    # Below may die if slchoosed goes down:
    # Our fork() loop will catch it and restart
    my $ok = $fh->send_and_check($msg);
    if (!$ok || !$fh || !$fh->connected()) { $self->{socket} = undef; }
}

######################################################################
######################################################################
######################################################################
#### Send_Hash loading

sub _fill_and_send {
    my $self = shift;
    # Fill dynamic values and send
    $self->_fill_stored;
    $self->_fill_dynamic;
    if ($self->{const_changed}) {
	$self->{const_changed} = 0;
	$self->_send_hash('const');
	$self->_send_hash('stored');
    }
    # Dynamic must be last, it triggers sending info back to user
    $self->_send_hash('dynamic');	
}

sub _fill_const {
    my $self = shift;
    # fill constant values into self
    # (Values that don't change with loading -- known at startup)
    $self->{const_changed} = 1;
 
    # Load our required keys
    $self->{const}{cpus}      ||= Unix::Processors->max_online();
    $self->{const}{max_clock} ||= Unix::Processors->max_clock();
    $self->{const}{osname}    ||= $Config{osname};
    $self->{const}{osvers}    ||= $Config{osvers};
    $self->{const}{archname}  ||= $Config{archname};
    foreach my $field (qw(reservable)) {
	$self->{const}{$field} = 0 if !defined $self->{const}{$field};
    }

    # Look for some special processes (assume init makes them)
    foreach my $p (@{$self->pt->table}) {
	if ($p->fname eq "nicercizerd") {
	    $self->{const}{nicercizerd} = 1;
	}
    }
}

sub _fill_dynamic_pid {
    my $self = shift;
    my $p = shift;	# Processtable entry
    my $pctcpu = shift;
    # Fill a single PID into the dynamic structures

    # Create hash
    $self->{dynamic}{proc}{$p->pid}{pid} = $p->pid;
    my $procref = $self->{dynamic}{proc}{$p->pid};

    # Copy the process table
    # We look inside the private hash, I've requested a new
    # version of ProcessTable to get around this intrusion.
    foreach (keys %{$p}) {
	$procref->{$_} = $p->{$_};
    }
    $procref->{pctcpu} = $pctcpu;

    # Elements that require special work
    if ($Os_Linux) {
	# Something funky is going on with linux
	$procref->{nice} = $p->priority / 1;
	$procref->{nice0} = $procref->{nice};
    } else {
	$procref->{nice0} = $procref->{nice} - 20;
    }

    $procref->{time} = $p->time / 1000.0;

    my $state = $p->state;
    $state = "cpu".$p->onpro if ($state eq "onprocessor");
    $procref->{state} = $state;

    my $uid = $p->uid;
    $uid ||= $p->euid if (exists ($p->{euid}));
    $procref->{uname} = $User_Names{$uid};
    if (!defined $procref->{uname}) {	# Cache user names
	$procref->{uname} = getpwuid($uid) || $uid;
	$User_Names{$uid} = $procref->{uname};
    }
}



sub _fill_dynamic {
    my $self = shift;
    # fill process and system loading values into self

    $self->{dynamic} = {total_load => 0,
		        fixed_load => 0,
			report_load => 0,
			total_pctcpu => 0,
		    };

    my ($sec, $usec) = gettimeofday();
    @Pid_Time_Base = ($sec,$usec) if !defined $Pid_Time_Base[0];
    my $deltastamp = ($sec-$Pid_Time_Base[0])*1e6 + ($usec-$Pid_Time_Base[1]);
    @Pid_Time_Base = ($sec,$usec);

    # Note the $p refs cannot be cached, they change when a new table call occurs
    my @pidlist;
    if (!$self->{fake}) {
	push @pidlist, @{$self->pt->table};
    }
    push @pidlist, @{$self->fake_pt->table};

    my %pidinfo = ();

    # Find all parental references (should cache this at some point)
    foreach my $p (@pidlist) {
	$pidinfo{$p->pid}{parent} = $p->ppid;
    }

    # Push all logit's down towards parents
    foreach my $p (@pidlist) {
	# See which PIDs we will log
	my $pctcpu = $p->pctcpu || 0;
	$pctcpu = 0 if ($pctcpu eq "inf");	# Linux
	if ($Distrust_Pctcpu) {
	    my $ustime = ($p->utime+$p->stime);
	    if (!$ustime
		|| !defined $Pid_Time[$p->pid]
		|| $p->start != $Pid_Time[$p->pid][0]) {
		# Can't calculate, as p->start is wrong (on linux).  We'll assume the
		# pctcpu is ok.
		#$pctcpu = $ustime / (1000*($sec-$p->start));
		printf "PIDSTART %d SINCESTART %d-%d=%d UTIME %d LOAD %f\n"
		    ,$p->pid, $sec, $p->start, $sec-$p->start, $ustime, $pctcpu
		    if 0;
	    } else {
		$pctcpu = 100*(( ($ustime-$Pid_Time[$p->pid][1]) * 1000)
			       / $deltastamp
			       );
		$pctcpu /= $self->{const}{cpus} if $Divide_Pctcpu_By_Cpu;
		printf "PIDCONT %d PCT %s CLOCK %d UTIME %d-%d=%d LOAD %f\n"
		    ,$p->pid, $p->pctcpu||0, $deltastamp,
		    ,$ustime, $Pid_Time[$p->pid][1], $ustime-$Pid_Time[$p->pid][1],
		    ,$pctcpu if 0;
	    }
	    $Pid_Time[$p->pid] = [$p->start, $ustime];
	}
	$pidinfo{$p->pid}{pctcpu} = $pctcpu;

	my $logit = ($pctcpu >= $self->{min_pctcpu}
		     && $p->pid != $$);	# Ignore ourself (hopefully not TOO much cpu time!)
	$pidinfo{$p->pid}{logit} = $logit;

	if ($p->uid) { # not root (speed things up)
	    my $searchpid = $p->pid;
	    #my $indent = 0;
	    while ($searchpid) {
		#printf " %s %s\n", $p->pid, " "x($indent++). $searchpid;
		$pidinfo{$searchpid}{logit_somechild} = 1 if $logit;
		$searchpid = $pidinfo{$searchpid}{parent};
	    }
	}
    }

    foreach my $p (@pidlist) {
	my $fixed_load = undef;
	my $cmndcomment = undef;
	my $logit = $pidinfo{$p->pid}{logit};
	if ($p->uid) { # not root
	    my $searchpid = $p->pid;
	    while ($searchpid) {
		if (defined $Pid_Inherit{$searchpid}) {
		    if ((!defined $fixed_load)
			&& defined $Pid_Inherit{$searchpid}{fixed_load}) {
			$fixed_load = $Pid_Inherit{$searchpid};
			if ($searchpid == $p->pid
			    && !$pidinfo{$searchpid}{logit_somechild}
			    ) {
			    $logit = 1;  # Show this fixed_load process, he has no children to show
			}
			printf "Found fixed_load %s\n", $p->pid if $Debug;
		    }
		    if ((!defined $cmndcomment) 
			&& defined $Pid_Inherit{$searchpid}{cmndcomment}) {
			$cmndcomment = $Pid_Inherit{$searchpid}{cmndcomment};
		    }
		}
		$searchpid = $pidinfo{$searchpid}{parent};
	    }
	}

	# Load any processes with lots of time, or with fixed_loading
	# that isn't otherwise accounted for
	my $pctcpu = $pidinfo{$p->pid}{pctcpu};
	if ($logit) {
	    _fill_dynamic_pid ($self, $p, $pctcpu);
	    $self->{dynamic}{proc}{$p->pid}{cmndcomment} = $cmndcomment if $cmndcomment;
	}

	# Count total loading
	$self->{dynamic}{total_pctcpu} += $pctcpu;
	if (($p->state eq "run" || $p->state eq "onprocessor")
	    && ($p->pid != $$)) {	# Exclude ourself
	    $self->{dynamic}{total_load} ++;
	    $self->{dynamic}{report_load} ++ if !defined $fixed_load;
	}
    }

    # Look for any fixed loads that died
    # Also add up fixed loading across all fixed_loads
    foreach my $pid (keys %Pid_Inherit) {
	if (!defined $pidinfo{$pid}
	    && $Pid_Inherit{$pid}{req_hostname} eq hostname()) {  # Not a fake load on a remote host
	    delete $Pid_Inherit{$pid};
	} else {
	    my $fixed_load = $Pid_Inherit{$pid}{fixed_load};
	    if (defined $fixed_load) {
		printf "Added fixed load for %s\n", $pid if $Debug;
		$self->{dynamic}{fixed_load} += $fixed_load;
	    }
	}
    }

    $self->{dynamic}{report_load} += $self->{dynamic}{fixed_load};
}

sub _fixed_load {
    my $self = shift;
    my $params = shift;

    my $load = $params->{load};
    my $pid = $params->{pid};
    print "Fixed load of $load PID $pid\n" if $Debug;
    $Pid_Inherit{$pid}{fixed_load} = $load;
    $Pid_Inherit{$pid}{pid} = $params->{pid};
    $Pid_Inherit{$pid}{uid} = $params->{uid};
    $Pid_Inherit{$pid}{req_pid} = $params->{req_pid};
    $Pid_Inherit{$pid}{req_hostname} = $params->{req_hostname} || $params->{host} || hostname();
    if ($load==0) {
	delete $Pid_Inherit{$pid};
    }
}

sub _comment {
    my $self = shift;
    my $params = shift;

    my $cmndcomment = $params->{comment};
    my $pid = $params->{pid};
    print "Command Commentary '$cmndcomment' PID $pid\n" if $Debug;
    $Pid_Inherit{$pid}{pid} = $pid;
    $Pid_Inherit{$pid}{uid} = $params->{uid};
    $Pid_Inherit{$pid}{cmndcomment} = $cmndcomment;
}

######################################################################
#### Sending the hash to slchoosed

sub _send_hash {
    my $self = shift;
    my $field = shift;
    # Send the hash over the file handle

    my $fh = $self->{socket};
    return if !$fh;
    my $ok = $fh->send_and_check(_pfreeze("report_$field", $self->{$field}, $Debug));
    if (!$ok || !$fh || !$fh->connected()) { $self->{socket} = undef; }
}

######################################################################
######################################################################
#### Existance

sub _exist_traffic {
    # Handle UDP responses from our $Exister->pid_request calls.
    print "UDP PidStat in...\n" if $Debug;
    my ($pid,$exists,$onhost) = $Exister->recv_stat();
    return if !defined $pid;
    return if $exists;   # We only care about known-missing processes
    print "  UDP PidStat PID $onhost:$pid no longer with us.  RIP.\n" if $Debug;
    foreach my $pref (values %Pid_Inherit) {
	if ($pref && $pref->{req_pid}==$pid && $pref->{req_hostname} eq $onhost) {
	    delete $Pid_Inherit{$pref->{pid}};
	}
    }
}

######################################################################
######################################################################
######################################################################
######################################################################
#### Stored configuration

sub _fill_stored {
    my $self = shift;
    # Get stored fields
    # SHOULD: If already cached, check the file date and reread if needed
    # BUT: Currently only this program changes it, so we don't care!
    if (!$self->{stored_read}) {
	$self->{stored} = {
	    reserved=>0,
	};
	if (defined $self->{stored_filename}
	    && -r $self->{stored_filename}) {
	    print "Retrieve $self->{stored_filename}\n" if $Debug;
	    $self->{stored} = retrieve($self->{stored_filename});
	}
	$self->{const_changed} = 1;
	$self->{stored_read} = 1;
    }
}

sub _set_stored {
    my $self = shift;
    my $params = shift;
    # Set a stored field to a given value
    
    $self->_fill_stored();	# Make sure up-to-date
    $self->{const_changed} = 1;

    foreach my $var (keys %{$params}) {
	my $value = $params->{$var};
	next if $var eq "host";
	print "_set_const($var = $value)\n" if $Debug;
	if ($params->{set_const}) {
	    $self->{const}{$var} = $value;
	} else {
	    $self->{stored}{$var} = $value;
	}
    }
    
    if (!$params->{set_const}
	&& defined $self->{stored_filename}) {
	print "Store $self->{stored_filename}\n" if $Debug;
	nstore $self->{stored}, $self->{stored_filename};
	chmod 0666, $self->{stored_filename};
    }
}

######################################################################
#### Package return
1;

######################################################################
__END__

=pod


=head1 NAME

Schedule::Load::Reporter - Distributed load reporting daemon

=head1 SYNOPSIS

  use Schedule::Load::Reporter;

  Schedule::Load::Reporter->start(dhost=>('host1', 'host2'),
				  port=>1234,);

=head1 DESCRIPTION

C<Schedule::Load::Reporter> on startup connects to the requested server
host and port.  The server connected to can then poll this host for
information about system configuration and current loading conditions.

=over 4

=item start ([parameter=>value ...]);

Starts the reporter.  Does not return.

=back

=head1 PARAMETERS

=over 4

=item dhost

List of daemon hosts that may be running the slchoosed server.  The second
host is only used if the first is down, and so on down the list.

=item port

The port number of slchoosed.  Defaults to 'slchoosed' looked up via
/etc/services, else 1752.

=item fake

Specifies load management should not be used, for reporting of a "fake"
hosts' status or scheduling a non-host related resource, like a license.

=item min_pctcpu

The minimum percentage of the CPU that a job must have to be included in
the list of top processes sent to the client.  Defaults to 3.  Setting to
0 will consume a lot of bandwidth.

=item stored_filename

The filename to store persistant items in, such as if this host is
reserved.  Must be either local-per-machine, or have the hostname in it.
Defaults to /usr/local/lib/rschedule/slreportd_{hostname}_store.  Set to
undef to disable persistance (thus if the machine reboots the reservation
is lost.)   The path must be **ABSOLUTE** as the deamons do a chdir.

=back

=head1 SEE ALSO

C<Schedule::Load>, C<slreportd>

=head1 DISTRIBUTION

This package is distributed via CPAN.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=cut
