# Schedule::Load::Chooser.pm -- distributed lock handler
# $Id: Chooser.pm,v 1.38 2002/09/24 13:15:07 wsnyder Exp $
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

package Schedule::Load::Chooser;
require 5.004;
require Exporter;
@ISA = qw(Exporter);

use POSIX;
use Socket;
use IO::Socket;
use IO::Select;
use Tie::RefHash;
use Net::hostent;
use Sys::Hostname;

use Schedule::Load qw (:_utils);
use Schedule::Load::Schedule;
use Schedule::Load::Hosts;

use strict;
use vars qw($VERSION $Debug %Clients $Hosts $Client_Num $Select
	    $Time $TimeStr
	    $Server_Self %Holds);
use Carp;

######################################################################
#### Configuration Section

# Other configurable settings.
$Debug = $Schedule::Load::Debug;

$VERSION = '2.102';

######################################################################
#### Globals

%Clients = ();
tie %Clients, 'Tie::RefHash';

$Time = time();	# Cache the time
$TimeStr = _timelog();

######################################################################
#### Creator

sub start {
    # Establish the server
    @_ >= 1 or croak 'usage: Schedule::Load::Chooser->start ({options})';
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = {
	%Schedule::Load::_Default_Params,
	#Documented
	cache_time=>2,	# Secs to hold cache for
	dead_time=>45,	# Secs lack of ping indicates dead
	@_,};
    bless $self, $class;
    $Server_Self = $self;	# Only should be one... Need some options

    # Open the socket
    print "$TimeStr Server up, listening on $self->{port}\n" if $Debug;
    my $server = IO::Socket::INET->new( Proto     => 'tcp',
					LocalPort => $self->{port},
					Listen    => SOMAXCONN,
					Reuse     => 1)
	or die "$0: Error, socket: $!";

    $Select = IO::Select->new($server);
    $Hosts = Schedule::Load::Schedule->new(_fetched=>-1,);  #Mark as always fetched

    $self->_probe_reset();

    while (1) {
	# Anything to read?
	foreach my $fh ($Select->can_read(3)) { #3 secs maximum
	    $Time = time();	# Cache the time
	    $TimeStr = _timelog() if $Debug;
	    if ($fh == $server) {
		# Accept a new connection
		print "Accept\n" if $Debug;
		my $clientfh = $server->accept();
		next if !$clientfh;
		$Select->add($clientfh);
		my $flags = fcntl($clientfh, F_GETFL, 0) or die "%Error: Can't get flags";
		fcntl($clientfh, F_SETFL, $flags | O_NONBLOCK) or die "%Error: Can't nonblock";
		my $client = {socket=>$clientfh,
			      delayed=>0,
			      ping => $Time,
			  };
		$Clients{$clientfh} = $client;
	    }
	    else {
		# Input traffic on other client
		_client_service($Clients{$fh});
	    }
	}
	# Action or timer expired, only do this if time passed
	if ($Time != time()) {
	    $Time = time();	# Cache the time
	    $TimeStr = _timelog() if $Debug;
	    _hold_timecheck();
	    _client_ping_timecheck();
	}
    }
}

######################################################################
#### Host probing

sub _probe_init {
    my $self = shift;
    # Create list of all hosts "below" this one on the list of all slchoosed servers

    my @hostlist = ($self->{dhost});
    @hostlist = @{$self->{dhost}} if (ref($self->{dhost}) eq "ARRAY");
    my $host_this = gethost(hostname());

    my $hit = 0;
    my @subhosts;
    foreach my $host (@hostlist) {
	my $hostx = $host;
	if (my $h = gethost($host)) {
	    print "_probe_init (host $host => ",$host_this->name,")\n" if $Debug;
	    if (lc($h->name) eq lc($host_this->name)) {
		$hit = 1;
	    } elsif ($hit) {
		push @subhosts, $host;
	    }
	}
    }
    print "_probe_init subhosts= (@subhosts)\n" if $Debug;
    $self->{_subhosts} = \@subhosts;
}

sub _probe_reset {
    my $self = shift;

    # Tell all subserviant hosts that a new master is on the scene.
    # Start at top and work down, want to ignore ourself and everyone
    # before ourself.
    $self->_probe_init();
    foreach my $host (@{$self->{_subhosts}}) {
	print "_probe_reset $host $self->{port} trying...\n" if $Debug;
	my $fhreset = Schedule::Load::Socket->new (
					     PeerAddr  => $host,
					     PeerPort  => $self->{port},
					     Timeout   => $self->{timeout},
					     );
	if ($fhreset) {
	    print "_probe_reset $host restarting\n" if $Debug;
	    print $fhreset _pfreeze("chooser_restart", {}, $Debug);
	    $fhreset->close();
	    print "_probe_reset $host DONE\n" if $Debug;
	}
    }
}

######################################################################
######################################################################
#### Client servicing

sub _client_close {
    # Close this client
    my $client = shift || die;

    my $fh = $client->{socket};
    print "$TimeStr Closing client $fh\n" if $Debug;

    if ($client->{host}) {
	my $host = $client->{host};
	my $hostname = $host->hostname || "";	# Will be deleted, so get before delete
	print "$TimeStr  Closing host ",$host->hostname,"\n" if $Debug;
	delete $host->{const};	# Delete before user_done, so user doesn't see them
	delete $host->{stored};
	delete $host->{dynamic};
	_user_done_finish ($host);
	delete $Hosts->{hosts}{$hostname};
    }

    $Select->remove($fh);
    eval {
	$fh->close();
    };
    delete $Clients{$fh};
}

sub _client_close_all {
    # For debugging; close all clients
    my @clients = (values %Clients);
    foreach (@clients) { _client_close ($_); }
}

sub _client_done {
    # Done with this client
    my $client = shift || die;
    _client_send($client, "DONE\n");
}

sub _client_service {
    # Loop getting commands from a specific client
    my $client = shift || die;
    
    my $fh = $client->{socket};
    my $data = '';
    my $rv = $fh->sysread($data, POSIX::BUFSIZ);
    if (!defined $rv || (length $data == 0)) {
	# End of the file
	_client_close ($client);
	return;
    }

    $client->{inbuffer} .= $data;
    $client->{ping} = $Time;

    while ($client->{inbuffer} =~ s/^([^\n]*)\n//) {
	my $line = $1;
	#print "CHOOSER GOT: $line\n" if $Debug;
	print "$TimeStr $client->{host}{hostname}  " if ($Debug && $client->{host});
	my ($cmd, $params) = _pthaw($line, $Debug);

	if ($cmd eq "report_ping") {
	    # NOP, timestamp recorded above
	} elsif ($cmd eq "report_const") {
	    _host_const ($client, $params);
	} elsif ($cmd eq "report_stored") {
	    _host_dynamic ($client, "stored", $params);
	} elsif ($cmd eq "report_dynamic") {
	    _host_dynamic ($client, "dynamic", $params);
	    $client->{host}{ping_update} = $Time;
	    _user_done_finish ($client->{host});
	}
	# User commands
	elsif ($cmd eq "get_const_load_proc") {
	    _user_get ($client, "report_get_dynamic\n", $cmd);
	} elsif ($cmd eq "schedule") {
	    _user_schedule ($client, $params);
	} elsif ($cmd =~ /^report_fwd_/) {	# All can just be forwarded
	    _user_to_reporter ($client, [$params->{host}], $line."\n");
	    _client_done ($client);
	} elsif ($cmd eq "hold_release") {
	    _hold_done ($params->{hold_key});
	    _client_done ($client);
	}
	# User reset
	elsif ($cmd eq "report_restart") {
	    _user_to_reporter ($client, '-all', "report_restart\n");
	    _client_done ($client);
	} elsif ($cmd eq "chooser_restart") {
	    # Overall fork loop will deal with it.
	    warn "-Info: chooser_restart\n" if $Debug;
	    exit(0);
	} elsif ($cmd eq "chooser_close_all") {
	    _client_close_all ($client);
	} else {
	    print "REQ UNKNOWN '$line\n" if $Debug;
	}
    }
}

sub _client_send {
    my $client = shift || die;
    my $out = join "", @_;
    # Send any arguments to the client
    # Returns 0 if failed, else 1

    $SIG{PIPE} = 'IGNORE';

    my $fh = $client->{socket};
    my $ok = Schedule::Load::Socket::send_and_check($fh, $out);
    if (!$ok) {
	_client_close ($client);
	return 0;
    }
    return 1;
}

sub _client_ping_timecheck {
    # See if any clients haven't pinged
    foreach my $client (values %Clients) {
	#print "Ping Check $client->{ping} Now $Time  Dead $Server_Self->{dead_time}\n" if $Debug;
	if ($client->{host} && ($client->{ping} < ($Time - $Server_Self->{dead_time}))) {
	    print "$TimeStr Client hasn't pinged lately, disconnecting\n" if $Debug;
	    _client_close ($client);
	}
    }
}

######################################################################
######################################################################
######################################################################
######################################################################
#### Services for slreportd calls

sub _host_const {
    my $client = shift || die;
    my $params = shift;
    # const command: establish a new host, load constants
    my $hostname = $params->{hostname};

    # Remove any earlier connection
    if (defined $Hosts->{hosts}{$hostname}{client}) {
	print "$TimeStr $hostname was connected before, reconnected\n" if $Debug;
	_client_close($Hosts->{hosts}{$hostname}{client});
    }

    # Only sent at first establishment, so we blow away old info
    print "$TimeStr Connecting $hostname\n" if $Debug;
    my $host = {  client => $client,
		  hostname => $hostname,
		  waiters => {},
		  ping => 0,
		  const => $params,
	      };
    bless $host, "Schedule::Load::Hosts::Host";

    tie %{$host->{waiters}}, 'Tie::RefHash';
    $Hosts->{hosts}{$hostname} = $host;
    $client->{host} = $host;
    #print "const: ", Data::Dumper::Dumper($host) if $Debug;
}

sub _host_dynamic {
    my $client = shift || die;
    my $field = shift;
    my $params = shift;
    # load/proc command: 

    $client->{host}{$field} = $params;

    if ($field eq "dynamic") {
	_hold_adjust ($client->{host});
    }
}

######################################################################
######################################################################
######################################################################
######################################################################
#### Services for user calls

sub _user_to_reporter {
    my $userclient = shift;
    my $hostnames = shift;	# array ref, or '-all'
    my $cmd = shift;

    if ($hostnames eq '-all') {
	my @hostnames = ();
	foreach my $host ($Hosts->hosts) {
	    push @hostnames, $host->hostname;
	}
	$hostnames = \@hostnames;
    }

    foreach my $hostname (@{$hostnames}) {
	my $host = $Hosts->{hosts}{$hostname};
	next if !$host;
	$host->{ping_update} = 0;	# Kill cache, will need refresh
	print "$TimeStr _user_to_reporter ->$hostname $cmd" if $Debug;
	_client_send ($host->{client}, $cmd);
    }
}

sub _user_get {
    my $userclient = shift;
    my $cmd = shift;
    my $flags = shift;
    
    _user_done_action ($userclient
		       , sub {
			   _user_send ($userclient, $flags);
			   _client_done ($userclient);
		       });
    _user_all_hosts_cmd ($userclient, $cmd);
    _user_done_check($userclient);
}

sub _user_all_hosts_cmd {
    my $userclient = shift;
    my $cmd = shift;
    foreach my $host ($Hosts->hosts) {
	print "$TimeStr GET ->", $host->hostname, " $cmd" if $Debug;
	if ($host->{ping_update} < ($Time - $Server_Self->{cache_time})) {
	    if (_client_send ($host->{client}, $cmd)) {
		# Mark that we need activity from each of these before being done
		_user_done_mark ($host, $userclient);
	    }
	}
    }
}

sub _user_send {
    my $client = shift;
    my $types = shift;
    # Send requested types of information back to the user
    print "$TimeStr _user_send $client $types\n" if $Debug;
    _user_send_type ($client, "const") if ($types =~ /const/);
    _user_send_type ($client, "stored") if ($types =~ /load/);
    _user_send_type ($client, "dynamic") if ($types =~ /load/ || $types =~ /proc/);
}

sub _user_send_type {
    my $client = shift;
    my $type = shift;
    # Send specific data type to user
    foreach my $host ($Hosts->hosts) {
	if (defined $host->{$type}) {
	    #print "$TimeStr Host $host name $host->{hostname}\n" if $Debug;
	    my %params = (table => $host->{$type},
			  type => $type,
			  hostname => $host->{hostname},
			  );
	    if (0==_client_send ($client, _pfreeze ("host", \%params, 0&&$Debug))) {
		last;	# Send failed
	    }
	}
    }
}

######################################################################

sub _user_done_action {
    my $userclient = shift;
    my $callback = shift;
    $userclient->{wait_action} = $callback;
    $userclient->{wait_count} = 0;
}

sub _user_done_mark {
    my $host = shift;
    my $userclient = shift;
    # Mark this user as needing new info from host before returning status

    $host->{waiters}{$userclient} = 1;
    $userclient->{wait_count} ++;
}

sub _user_done_finish {
    my $host = shift;
    # Host finished, dec count see if done with everything client needed

    foreach my $userclient (keys %{$host->{waiters}}) {
	print "$TimeStr Dewait $host $userclient\n" if $Debug;
	delete $host->{waiters}{$userclient};
	$userclient->{wait_count} --;
	_user_done_check($userclient);
    }
}

sub _user_done_check {
    my $userclient = shift;
    if ($userclient->{wait_count} == 0) {
	print "$TimeStr Dewait *DONE*\n" if $Debug;
	&{$userclient->{wait_action}}();
    }
}

######################################################################
######################################################################
######################################################################
######################################################################
#### Scheduling

sub _user_schedule_sendback {
    my $userclient = shift;
    my $schparams = shift;
    # Schedule and return results to the user

    my $schresult = _schedule ($schparams);
    _client_send ($userclient, _pfreeze ("best", $schresult, $Debug));
    _client_done ($userclient);
}    

sub _user_schedule {
    my $userclient = shift;
    my $schparams = shift;
    
    _user_done_action ($userclient
		       , sub {
			   _user_schedule_sendback($userclient, $schparams);
		       });
    _user_all_hosts_cmd ($userclient, "report_get_dynamic\n");
    _user_done_check($userclient);
}

sub _schedule {
    # Choose the best host and total resources available for scheduling
    my $schparams = shift;  #favor_host, classes, _is_night
    
    my $freejobs = 0;
    my $bestref = undef;
    my $bestload = undef;
    my $favorref = undef;
    my $favorhost = $Hosts->get_host($schparams->{favor_host}) || 0;
    my $freecpu = 0;
    foreach my $host (@{$Hosts->hosts}) {
	#print "What about ", $host->hostname, "\n" if $Debug;
	if ($host->classes_match ($schparams->{classes})
	    && $host->eval_match ($schparams->{match_cb})
	    && !$host->reserved) {
	    my $rating = $host->rating ($schparams->{rating_cb});
	    #print "Test host ", $host->hostname," rate $rating\n" if $Debug;
	    #print Data::Dumper->Dump([$host], ['host']),"\n" if $Debug;
	    if ($rating > 0) {
		my $machjobs = ($host->cpus - $host->adj_load);
		$machjobs = 0 if ($machjobs < 0);
		$machjobs = int ($machjobs + .7);
		$freejobs += $machjobs;
		if ($host == $favorhost && $machjobs) {
		    # Found the favored host has resources, force it to win
		    $favorref = $host;
		    $bestref = undef; # For next if statement to catch
		}
		if (!defined $bestref
		    || (($rating < $bestload) && !$favorref)) {
		    $bestref = $host;
		    $bestload = $rating;
		    $freecpu = 1 if $machjobs > 0;
		}
	    }
	}
    }

    my $jobs = $freejobs;
    if ($schparams->{max_jobs}<=0) {  # Fraction that's percent of clump if negative
	$jobs = int($freejobs * (-$schparams->{max_jobs}));
    } else {
	$jobs = _min($jobs, $schparams->{max_jobs});
    }
    $jobs = _min($jobs, $freejobs);
    $jobs = _max($jobs, 1);

    if ($schparams->{allow_none} && !$freecpu) {
	$bestref = undef;
    }

    if ($bestref && $schparams->{hold_key}) {
	$Holds{$schparams->{hold_key}} = {
	    hostname=>$bestref->hostname,
	    expires=>($Time + $schparams->{hold_time}),
	    hold_load=>($schparams->{hold_load}||1),
	};
	_hold_adjust ($bestref);
    }

    return {jobs => $jobs,
	    best => $bestref ? $bestref->hostname : undef,
	    hold_key => $schparams->{hold_key},
	};
}

######################################################################
######################################################################
#### Holds

sub _hold_timecheck {
    # See if any holds have expired; if so delete them
    foreach my $key (keys %Holds) {
	if ($Time > $Holds{$key}{expires}) {
	    #print "HOST DONE MARK $host $hostname $key EXP $Holds{$hostname}{$key}{expires}\n" if $Debug;
	    _hold_done ($key);
	}
    }
}

sub _hold_done {
    my $key = shift;
    # Remove a load hold on this machine

    print "$TimeStr _hold_done($key)\n" if $Debug;
    return if !defined $Holds{$key};
    my $host = $Hosts->get_host($Holds{$key}{hostname});
    delete $Holds{$key};
    warn "No host $host" if !$host && $Debug;
    _hold_adjust ($host, 1) if $host;
}

sub _hold_adjust {
    my $host = shift;
    my $skip_timecheck = shift;
    # Adjust loading on specified machine to make up for actual load

    _hold_timecheck() if !$skip_timecheck;
    #print Data::Dumper::Dumper (\%Holds) if $Debug;
    my $hostname = $host->hostname;
    my $adj = $host->{dynamic}{report_load};
    foreach my $holdkey (keys %Holds) {
	if ($Holds{$holdkey}{hostname} eq $hostname) {
	    $adj += $Holds{$holdkey}{hold_load};
	}
    }
    $host->{dynamic}{adj_load} = $adj;
}

######################################################################
######################################################################
#### Little stuff

sub _timelog {
    my ($sec,$min,$hour,$mday,$mon) = localtime($Time);
    return sprintf ("[%02d/%02d %02d:%02d:%02d] ", $mon+1, $mday, $hour, $min, $sec);
}

######################################################################
######################################################################
#### Package return
1;

######################################################################
__END__

=pod

=head1 NAME

Schedule::Load::Chooser - Distributed load choosing daemon

=head1 SYNOPSIS

  use Schedule::Load::Chooser;

  Schedule::Load::Chooser->start(port=>1234,);

=head1 DESCRIPTION

C<Schedule::Load::Chooser> on startup creates a daemon that clients can
connect to using the Schedule::Load package.

=over 4

=item start ([parameter=>value ...]);

Starts the chooser daemon.  Does not return.

=head1 PARAMETERS

=item port

The port number of slchoosed.  Defaults to 'slchoosed' looked up via
/etc/services, else 1752.

=item dead_time

=head1 SEE ALSO

C<Schedule::Load>, C<slchoosed>

=head1 DISTRIBUTION

This package is distributed via CPAN.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=cut
