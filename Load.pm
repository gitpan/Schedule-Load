# Load.pm -- Schedule load management
# $Id: Load.pm,v 1.36 2000/01/21 14:26:04 wsnyder Exp $
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

require 5.005;
package Schedule::Load;
require Exporter;
@ISA = ('Exporter');
@EXPORT = qw( );
@EXPORT_OK = qw(_min _max _nfreeze _nthaw _pfreeze _pthaw);
%EXPORT_TAGS = (_utils => \@EXPORT_OK);

use vars qw($VERSION $Debug %Machines %_Default_Params $Default_Port @Default_Hosts);

use IO::Pipe;
use IO::File;
use IO::Socket;
use Sys::Hostname;
use Storable qw (nfreeze thaw);
use Socket;
require Exporter;
BEGIN { eval 'use Data::Dumper';}	#Ok if doesn't exist: debugging only
use strict;
use Carp;

######################################################################
#### Configuration Section

$VERSION = '1.2';
$Debug = 0;

%_Default_Params = (
		    min_pctcpu=>3,
		    port=>1752,
		    dhost=> [(defined $ENV{SLCHOOSED_HOST})
			     ? split ':', $ENV{SLCHOOSED_HOST}
			     : qw(localhost)],
		    );

######################################################################
#### Internal utilities 

sub _subprocesses {
    my $parent = shift || $$;
    # All pids under the given parent
    # Used by testing module
    use Proc::ProcessTable;
    my $pt = new Proc::ProcessTable( 'cache_ttys' => 1); 
    my %parent_pids;
    foreach my $p (@{$pt->table}) {
	$parent_pids{$p->pid} = $p->ppid;
    }
    my @out;
    my @search = ($parent);
    while ($#search > -1) {
	my $pid = shift @search;
	push @out, $pid if $pid ne $parent;
	foreach (keys %parent_pids) {
	    push @search, $_ if $parent_pids{$_} == $pid;
	}
    }
    return @out;
}

sub _min {
    return $_[0] if (!defined $_[1]);
    return $_[1] if (!defined $_[0]);
    return $_[0] if ($_[0] <= $_[1]);
    return $_[1];
}
sub _max {
    return $_[0] if (!defined $_[1]);
    return $_[1] if (!defined $_[0]);
    return $_[0] if ($_[0] >= $_[1]);
    return $_[1];
}

sub _pfreeze {
    my $cmd = shift;
    my $ref = shift;
    my $debug = shift;

    my $serialized = $cmd . " " . unpack ("h*", nfreeze $ref) . "\n";
    if ($debug) {
	printf "AFREEZE $cmd: %s\n", Data::Dumper::Dumper($ref);
    }
    return $serialized;
}

sub _pthaw {
    my $line = shift;
    my $debug = shift;

    $line =~ /^(\S+)\s*(\S*)/;
    my $cmd = $1; my $serialized = $2;

    my $ref = thaw(pack ("h*", $serialized)) if $serialized;
    if ($debug) {
	printf "$cmd: %s\n", Data::Dumper::Dumper($ref);
    }
    return ($cmd, $ref);
}

######################################################################
#### Package return
1;

######################################################################
__END__

=pod

=head1 NAME

Schedule::Load - Load distribution and status across multiple host machines

=head1 SYNOPSIS

  # Get per-host or per top process information
  use Schedule::Load::Hosts;
  foreach my $host ($hosts->hosts) {
      printf $host->hostname " is on our network\n";
  }

  # Choose hosts
  use Schedule::Load::Schedule;
  my $scheduler = Schedule::Load::Schedule->fetch();
  print "Best host for a new job: ", $scheduler->best();

  # user access
  rtop
  rschedule reserve <hostname>

=head1 DESCRIPTION

This package provides useful utilities for load distribution and status
across multiple machines in a network.  To just see what is up in the
network, see the C<rschedule> or C<rtop>, C<rloads> or C<rhosts> commands.

The system is composed of four unix programs (each also with a underlying
Perl module):

=over 4 

=item slreportd

C<slreportd> is run on every host in the network, usually started with a
init.d script.  It reports itself to the C<slchoosed> daemon periodically,
and is responsible for checking loading and top processes specific to the
host that it runs on.

C<slreportd> may also be invoked with some variables set.  This allows
static host information, such as class settings to be passed to
applications.

=item slchoosed

C<slchoosed> is run on one host in the network.  It collects connections
from the C<slreportd> reporters, and maintains a internal database of the
entire network.  User clients also connect to the chooser, which then gets
updated information from the reporters, and returns the information to the
user client.  As the chooser has the entire network state, it can also
choose the best host across all CPUs in the network.

=item rschedule

C<rschedule> is a command line interface to this package.  It and the
aliases C<rtop>, C<rhosts>, and C<rloads> report the current state of the
network including hosts and top loading.  C<rschedule> also allows reserving
hosts and setting the classes of the machines, as described later.

=item slpolice

C<slpolice> is a optional client daemon which is run as a C<cron> job.
When a user process has over a hour of CPU time, it C<nice>s that process
and sends mail to the user.  It is intended as a example which can be used
directly or changed to suit the system manager preferences.

=back

=head1 MODULES

=over 4 

=item Schedule::Load::Hosts

C<Schedule::Load::Hosts> provides the connectivity to the C<slchoosed>
daemon, and accessors to load and modify that information.

=item Schedule::Load::Schedule

C<Schedule::Load::Schedule> provides functions to choose the best host for
a new job, reserving hosts, and for setting what hosts specific classes of
jobs can run on.

=item Schedule::Load::Reporter

C<Schedule::Load::Reporter> implements the internals of C<slreportd>.

=item Schedule::Load::Chooser

C<Schedule::Load::Chooser> implements the internals of C<slchoosed>.

=back

=head1 RESERVATIONS

Occasionally clusters have members that are only to be used by specific
people, and not for general use.  A host may be reserved with C<rschedule
reserve>.  This will place a special comment on the machine that
C<rschedule hosts> will show.  Reservations also prevent the
C<Schedule::Load::Schedule> package from picking that host as the best
host.

To be able to reserve a host, the reservable variable must be set on that
host.  This is generally done when C<slreportd> is invoked on the
reservable host by using C<slreportd reservable=1>.

=head1 CLASSES

Different hosts often have different properties, and jobs need to be able
select a host with certain properties, such as hardware or licensing
requirements.  Classes are generally just boolean variables which start
with class_.  Classes can be specified when C<slreportd> is invoked on the
C<slreportd class_foo=1>.  The class setting may be seen with C<rschedule
classes> or may be read (as may any other variable) as a accessor from a
C<Schedule::Load::Hosts::Host> object.

Once a class is defined, a scheduling call can include it the classes array
that is passed when the best host is requested.  Only machines which match
one of those classes will be selected.

=head1 COMMAND COMMENTS

C<rschedule loads> or C<rloads> show the command that is being run.  By
default this is the basename of the command invoked, as reported by the
operating system.  Often this is of little use, especially when the same
program is used by many people.  The C<rschedule cmnd_comment> command or
C<Schedule::Load::Schedule::cmnd_comment> function will assign a more
verbose command to that process id.  For example, we use dc_shell, and put
the name of the module being compiled into the comment, so rather then
several copies of the generic "dc_shell" we see "dc module", "dc module2",
etc.

=head1 HOLD KEYS

When a best host is picked for a new job, there is often a lag before a
process actually starts up on the selected host, and enough CPU time
elapses for that new process to claim CPU time.  To prevent another job
from scheduling onto that host during this lag, scheduling calls may
specify a hold key.  For a limited time, the load on the host will be
incremented.  When the job begins and a little CPU time has elapsed a
hold_release call may be made, (or the timer expires), which releases the
hold.  This will cause the load reported by C<rschedule hosts> to
occasionally be higher then the number of jobs on that host.

=head1 FIXED LOADS

Some jobs have CPU usage patterns which contain long periods of low CPU
activity, such as when doing disk IO.  C<make> is a typical example; the
parent make process uses little CPU time, but the children of the make pop
in and out of the cpu run list.

When scheduling, it is useful to have such jobs always count as one (or
more) job, so that the idle time is not misinterpreted and another job
scheduled onto that machine.  Fixed loading allows all children of a given
parent to count as a given fixed CPU load.  Using C<make> again, if the
parent make process is set as a fixed_load of one, the make and all
children will always count as one load, even if not consuming CPU
resources.  The C<rschedule loads> or C<rloads> command includes not only
top cpu users, but also all fixed loads.  If a child process is using CPU
time, that is what is displayed.  If no children are using appreciable CPU
time (~2%), the parent is the one shown in the loads list.

=head1 DISTRIBUTION

The latest version is available from CPAN.

=head1 SEE ALSO

User program for viewing loading, etc:

C<rschedule>

Daemons:

C<slreportd>, C<slchoosed>, C<slpolice>

Perl modules:

C<Schedule::Load::Chooser>, C<Schedule::Load::Hosts::Host>,
C<Schedule::Load::Hosts::Proc>, C<Schedule::Load::Hosts>,
C<Schedule::Load::Reporter>, C<Schedule::Load::Schedule>

=head1 AUTHORS

Wilson Snyder <wsnyder@world.std.com>

=cut
