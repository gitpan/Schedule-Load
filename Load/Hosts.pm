# Schedule::Load::Hosts.pm -- Loading information about hosts
# $Id: Hosts.pm,v 1.30 2001/12/06 18:14:45 wsnyder Exp $
######################################################################
#
# This program is Copyright 2000 by Wilson Snyder.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of either the GNU General Public License or the
# Perl Artistic License, with the exception that it cannot be placed
# on a CD-ROM or similar media for commercial distribution without the
# prior approval of the author.
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

package Schedule::Load::Hosts;
require 5.004;
require Exporter;
@ISA = qw(Exporter);

use Socket;

use Schedule::Load qw(:_utils);
use Schedule::Load::Hosts::Host;
use Schedule::Load::Hosts::Proc;
use Time::localtime;
use Sys::Hostname;

use strict;
use vars qw($VERSION $Debug);
use Carp;

######################################################################
#### Configuration Section

# Other configurable settings.
$Debug = $Schedule::Load::Debug;

$VERSION = '1.7';

######################################################################
#### Globals

######################################################################
#### Creator

sub new {
    @_ >= 1 or croak 'usage: Schedule::Load::Hosts->new ({options})';
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = {
	%Schedule::Load::_Default_Params,
	username=>($ENV{USER}||""),
	#Internal
	@_,};
    bless $self, $class;
    return $self;
}

######################################################################
#### Constructor

sub fetch {
    my $self = shift;
    $self = $self->new(@_) if (!ref($self));
    return if $self->{_fetched} && $self->{_fetched}<0;
    # Erase current structures in case a host goes down
    delete $self->{hosts};
    # Make the request
    $self->_request("get_const_load_proc\n");
    $self->{_fetched} = 1;
    return $self;
}

sub _fetch_if_unfetched {
    my $self = shift;
    $self->fetch() if (!$self->{_fetched});
    return $self;
}
sub kill_cache {
    my $self = shift;
    $self->{_fetched} = 0;
}

sub restart {
    my $self = shift;
    my $params = {
	chooser=>1,
	reporter=>1,
	@_,};
    $self->_request("chooser_restart\n") if $params->{chooser};
    $self->_request("report_restart\n") if $params->{reporter};
}
sub _chooser_close_all {
    my $self = shift;
    $self->_request("chooser_close_all\n");
}

######################################################################
#### Accessors

sub hosts {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts()';
    # Return all hosts, potentially matching given classes

    $self->_fetch_if_unfetched;
    my @keys;
    foreach my $host (values %{$self->{hosts}}) {
	push @keys, $host if ($host->exists('hostname') && $host->hostname);
    }
    @keys = (sort {$a->hostname cmp $b->hostname} @keys);
    return (wantarray ? @keys : \@keys);
}

sub get_host {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->get_host(hostname)';
    my $hostname = shift;

    $self->_fetch_if_unfetched;
    return $self->{hosts}{$hostname};
}

sub classes {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->classes()';

    my %classes = ();
    $self->_fetch_if_unfetched;
    foreach my $host ( @{$self->hosts} ){
	foreach (sort ($host->fields)) {
	    # Ignore classes that are set to 0
	    $classes{$_} = 1 if /^class_/ && $host->get($_);
	}
    }
    my @classes = (keys %classes);
    return (wantarray ? @classes : \@classes);
}

######################################################################
######################################################################
#### Totals across all hosts

sub cpus {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->classes()';
    # Return number of cpus for a given class

    $self->_fetch_if_unfetched;
    my $jobs = 0;
    foreach my $host ( @{$self->hosts} ){
	$jobs += $host->cpus();
    }
    return $jobs;
}

sub idle_host_names {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts()';
    # Return idle hosts, potentially matching given classes
    # Roughly scaled so even powered hosts have even representation

    $self->_fetch_if_unfetched;
    my @hnames;
    foreach my $host (values %{$self->{hosts}}) {
	if ($host->exists('hostname') && $host->hostname
	    && !$host->reserved) {
	    my $idleCpus = $host->cpus - $host->adj_load;
	    for (my $c=0; $c<$idleCpus; $c++) {
		push @hnames, $host->hostname;
	    }
	}
    }
    @hnames = (sort @hnames);
    return (wantarray ? @hnames : \@hnames);
}

######################################################################
######################################################################
#### Information printing

sub digit {
    my $host = shift;
    my $field = shift;
    return " " if !$host->exists($field);
    my $val = $host->get($field);
    return " " if !$val;
    return "*" if $val>9;
    return $val;
}

sub print_hosts {
    my $hosts = shift;
    # Overall machine status
    my $out = "";
    (my $FORMAT =           "%-12s    %4s     %4s   %6s%%       %5s   %5s     %2s    %s\n") =~ s/\s\s+/ /g;
    $out.=sprintf ($FORMAT, "HOST", "CPUs", "FREQ", "TotCPU", "LOAD", "RATE", "RL", "ARCH/OS");
    foreach my $host ( @{$hosts->hosts} ){
	my $ostype = $host->archname ." ". $host->osvers;
	foreach (sort ($host->fields)) {
	    $ostype .= " $_" if (/^lab_/);
	}
	$ostype = "Reserved: ".$host->reserved if ($host->reserved);
	$out.=sprintf ($FORMAT,
		       $host->hostname, 
		       $host->cpus, 
		       $host->max_clock, 
		       sprintf("%3.1f", $host->total_pctcpu), 
		       $host->adj_load, 
		       ( ($host->rating && !$host->reserved)
			 ?sprintf("%4.2f", $host->rating):"inf"), 
		       ( ($host->reservable?"R":" ")
			 . digit($host,'load_limit')),
		       $ostype,
		       );
    }
    return $out;
}

sub print_top {
    my $hosts = shift;
    # Top processes
    my $out = "";
    (my $FORMAT =           "%-12s   %6s    %-8s     %4s    %6s     %-5s    %6s     %5s%%    %s\n") =~ s/\s\s+/ /g;
    $out.=sprintf ($FORMAT, "HOST", "PID", "USER", "NICE", "MEM", "STATE", "RUNTM", "CPU","COMMAND"); 
    foreach my $host ( @{$hosts->hosts} ){
	foreach my $p ( sort {$b->pctcpu <=> $a->pctcpu}
			@{$host->top_processes} ) {
	    next if ($p->pctcpu < $hosts->{min_pctcpu});
	    my $comment = ($p->exists('cmndcomment')? $p->cmndcomment:$p->fname);
	    $out.=sprintf ($FORMAT, 
			   $host->hostname,
			   $p->pid, 
			   $p->uname,		$p->nice0, 
			   int(($p->size||0)/1024/1024)."M",
			   $p->state, 		$p->time_hhmm,
			   sprintf("%3.1f", $p->pctcpu),
			   substr ($comment,0,18),
			   );
	}
    }
    return $out;
}

sub print_loads {
    my $hosts = shift;
    # Top processes
    my $out = "";
    (my $FORMAT =           "%-12s   %6s    %-8s    %6s     %5s%%    %s\n") =~ s/\s\s+/ /g;
    $out.=sprintf ($FORMAT, "HOST", "PID", "USER", "RUNTM", "CPU","COMMAND"); 
    foreach my $host ( @{$hosts->hosts} ){
	foreach my $p ( sort {$b->pctcpu <=> $a->pctcpu}
			@{$host->top_processes} ) {
	    my $comment = ($p->exists('cmndcomment')? $p->cmndcomment:$p->fname);
	    $out.=sprintf ($FORMAT, 
			   $host->hostname,
			   $p->pid, 
			   $p->uname, 		$p->time_hhmm,
			   sprintf("%3.1f", $p->pctcpu),
			   $comment,
			   );
	}
    }
    return $out;
}

sub print_kills {
    my $hosts = shift;
    # Top processes
    my $out = "";
    foreach my $host ( @{$hosts->hosts} ){
	foreach my $p ( sort {$b->pctcpu <=> $a->pctcpu}
			@{$host->top_processes} ) {
	    $out.=sprintf ("ssh %s kill %s\n", 
			   $host->hostname,
			   $p->pid, 
			   );
	}
    }
    return $out;
}

sub print_classes {
    my $hosts = shift;
    # Host classes
    my $out = "";

    my @classes = (sort ($hosts->classes()));
    my $classnum = 0;
    my %class_letter = ();
    foreach my $class (@classes) {
	$class_letter{$class} = chr($classnum%26+ord("a"));
	$classnum++;
    }
    my $classes = $classnum;
    $classnum = 0;
    foreach my $class (@classes) {
	$class_letter{$class} = chr($classnum%26+ord("a"));
	$out.=sprintf ("%-12s  %s%s%s %s\n",
		       ($classnum==$classes-1)?"HOST":"", 
		       "| "x$classnum, 
		       $class_letter{$class}, "--"x($classes-$classnum),
		       $class);
	$classnum++;
    }
    foreach my $host ( @{$hosts->hosts} ){
	$out .= sprintf "%-12s ", $host->hostname;
	$classnum = 0;
	foreach my $class (@classes) {
	    if ($host->exists($class) && $host->get($class)) {
		$out .= sprintf (" %s", $class_letter{$class});
	    } else {
		$out .= sprintf (" .");
	    }
	    $classnum++;
	}
	$out .= "\n";
    }
    return $out;
}

######################################################################
######################################################################
#### User requests

sub cmnd_comment {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->cmnd_comment)';
    my $params = {
	host=>hostname(),
	comment=>undef,
	pid=>$$,
	@_,};

    print __PACKAGE__."::cmnd_comment($params->{comment})\n" if $Debug;
    (defined $params->{comment}) or croak 'usage: cmnd_comment needs comment parameter)';
    $self->_request(_pfreeze( 'report_fwd_comment', $params, $Debug));
}

######################################################################
######################################################################
#### Guts: Sending and receiving messages

sub _open {
    my $self = shift;

    my @hostlist = ($self->{dhost});
    @hostlist = @{$self->{dhost}} if (ref($self->{dhost}) eq "ARRAY");

    my $fh;
    foreach my $host (@hostlist) {
	print "Trying host $host\n" if $Debug;
	$fh = Schedule::Load::Socket->new(
					  PeerAddr  => $host,
					  PeerPort  => $self->{port},
					  );
	if ($fh) {
	    print "Opened $host\n" if $Debug;
	    last;
	}
    }
    if (!$fh) {
	if (defined $self->{print_down}) {
	    &{$self->{print_down}} ($self);
	    return;
	}
	croak "%Error: Can't locate slchoosed server on " . (join " or ", @hostlist), " $self->{port}\n"
	    . "\tYou probably need to run slchoosed\n$self->_request(): Stopped";
    }
    $self->{_fh} = $fh;
}

sub _request {
    my $self = shift;
    my $cmd = shift;

    if (!defined $self->{_fh}) {
	$self->_open;
    }
    my $fh = $self->{_fh};
    
    print "_request-> $cmd\n" if $Debug;
    print $fh $cmd;
    my $line;
    while (defined ($line = <$fh>)) {
	chomp $line;
	#print "GOT $line\n" if $Debug;
	my ($cmd, $params) = _pthaw($line, $Debug);
	next if $line =~ /^\s*$/;
	last if $cmd eq "DONE";
	if ($cmd eq "host") {
	    $self->_host_load ($params);
	} elsif ($cmd eq "best") {
	    $self->{_best} = $params;
	} else {
	    warn "%Warning: Bad Schedule::Load server response: $line\n";
	    $line = undef;
	}
    }
    if (!defined $line) {
	$fh->close();
	undef $self->{_fh};
    }
}

######################################################################
#### Loading

sub _host_load {
    my $self = shift;
    my $params = shift;
    # load/proc command (also used by Chooser)
    # Load a Hosts::Host hash, bless, and load given field
    # Move perhaps to Hosts::Host->new.

    my $hostname = $params->{hostname};
    my $field = $params->{type};

    $self->{hosts}{$hostname}{$field} = $params->{table};
    bless $self->{hosts}{$hostname}, "Schedule::Load::Hosts::Host";
}

######################################################################
######################################################################
#### Utilities

######################################################################
#### Package return
1;

######################################################################
__END__

=pod


=head1 NAME

Schedule::Load::Hosts - Return host loading information across a network

=head1 SYNOPSIS

    use Schedule::Load::Hosts;

    my $hosts = Schedule::Load::Hosts->fetch();
    $hosts->print_machines();
    $hosts->print_top();

    # Overall machine status
    my $hosts = Schedule::Load::Hosts->fetch();
    (my $FORMAT =    "%-12s    %4s     %4s   %6s%%       %5s    %s\n") =~ s/\s\s+/ /g;
    printf ($FORMAT, "HOST", "CPUs", "FREQ", "TotCPU", "LOAD", "ARCH/OS");
    foreach my $host ($hosts->hosts) {
	printf STDOUT ($FORMAT,
		       $host->hostname, 
		       $host->cpus, 
		       $host->max_clock, 
		       sprintf("%3.1f", $host->total_pctcpu), 
		       $host->adj_load, 
		       $host->archname ." ". $host->osvers, 
		       );
    }

    # Top processes
    (my $FORMAT =    "%-12s   %6s    %-8s      %-5s    %6s     %5s%%    %s\n") =~ s/\s\s+/ /g;
    printf ($FORMAT, "HOST", "PID", "USER",  "STATE", "RUNTM", "CPU","COMMAND"); 
    foreach my $host ($hosts->hosts) {
	foreach $p ($host->top_processes) {
	    printf($FORMAT, 
		   $host->hostname,
		   $p->pid, 		$p->uname,		
		   $p->state, 		$p->time_hhmm,
		   $p->pctcpu,		$p->fname);
	}
    }

=head1 DESCRIPTION

This package provides information about host loading and top processes
from many machines across a entire network.

=over 4 

=item fetch ()

Fetch the data structures from across the network.  This also creates
a new object.  Accepts the port and host parameters.

=item restart ()

Restart all daemons, loading their code from the executables again.  Use
sparingly.  chooser parameter if true (default) restarts chooser, reporter
parameter if true (default) restarts reporter.

=item hosts ()

Returns the host objects, accessable with C<Schedule::Load::Hosts::Host>.
In an array context, returns a list; In a a scalar context, returns a
reference to a list.

=item idle_host_names (...)

Returns a list of host cpu names which are presently idle.  Multiple
free CPUs on a given host will result in that name being returned multiple
times.

=item get_host ($hostname)

Returns a reference to a host object with the specified hostname,
or undef if not found.

=item classes ()

Returns all class_ variables under all hosts.  In an array context, returns
a list; In a a scalar context, returns a reference to a list.

=item print_classes

Returns a string with the list of machines and classes that may run on them
in a printable format.

=item print_hosts

Returns a string with the list of host machines and loading in a printable
format.

=item print_top

Returns a string with the top jobs on all machines in a printable format,
ala the C<top> program.

=item print_loads

Returns a string with the top jobs command lines, including any jobs with
a fixed loading.

=back

=head1 PARAMETERS

=over 4

=item dhost

List of daemon hosts that may be running the slchoosed server.  The second
host is only used if the first is down, and so on down the list.

=item port

The port number of slchoosed.  Defaults to 'slchoosed' looked up via
/etc/services, else 1752.

=back

=head1 SEE ALSO

C<Schedule::Load::Hosts::Host>, C<Schedule::Load::Hosts::Proc>

C<Schedule::Load>, C<rschedule>

=head1 DISTRIBUTION

The latest version is available from CPAN.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=cut
