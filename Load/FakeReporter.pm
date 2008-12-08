# Schedule::Load::FakeReporter.pm -- distributed lock handler
######################################################################
#
# Copyright 2000-2006 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# General Public License or the Perl Artistic License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
######################################################################

package Schedule::Load::FakeReporter;
use Schedule::Load::Reporter;  # For ProcTimeToSec
require 5.004;
@ISA = qw(Schedule::Load::Reporter);

use strict;
use vars qw($VERSION);
use Carp;
use POSIX;

######################################################################
#### Configuration Section

$VERSION = '3.060';

######################################################################
#### Local process table

package Schedule::Load::FakeReporter::ProcessTable;
use vars qw (@ISA);
#Same functions as: @ISA = qw(Proc::ProcessTable);
use IPC::PidStat;
use Sys::Hostname;
use strict;

sub new {
    my ($this, %args) = @_;
    my $class = ref($this) || $this;
    my $self = {%args};	# reportref=>  Reporter's SELF so can get variables
    bless $self, $class;
    return $self;
}

sub table {
    my $self = shift;  #proctable, not reporter
    my @pids;

    my $load_limit = $self->{reportref}{const}{load_limit} || 1;
    my $pid_track  = $self->{reportref}{const}{pid_track};
    $pid_track=1 if !defined $pid_track;

    while (my ($pid,$pref) = each %Schedule::Load::Reporter::Pid_Inherit) {
	if ($pid_track) {
	    if ($pref->{req_hostname} eq hostname()) {
		if (IPC::PidStat::local_pid_doesnt_exist($pid)) {
		    # Process being tracked died.  fill_dynamic will delete the hash element
		    delete $Schedule::Load::Reporter::Pid_Inherit{$pid};
		    next;
		} elsif (!$self->{reportref}{fake}) {
		    # Process exists and this isn't a fake reporter.  We'll get real CPU information
		    # from the reporter
		    next;
		}
	    } else {
		# Remote process, launch a request to make sure it's still alive
		$Schedule::Load::Reporter::Exister->pid_request(host=>$pref->{req_hostname},
								pid=>$pref->{req_pid},);
	    }
	}
        if ($pref->{fixed_load}) {  # Else it might only be a comment
	    $pref->{start} ||= time();
	    my $pctcpu = 100*int(($pref->{fixed_load}||1)/ $load_limit);
	    my $time = (time()-$pref->{start})*($pctcpu/100);
	    # Convert TO process time, as Reporter will convert proc back to seconds
	    $time = $time / $Schedule::Load::Reporter::ProcTimeToSec;

	    my $proc = Schedule::Load::FakeReporter::ProcessTable::Process->new
		(pid=>$pid,
		 ppid=>0,
		 pctcpu=>$pctcpu,
		 utime=>0, stime=>0,
		 start=>$pref->{start},
		 time=>$time,  # Is in usec
		 uid=>$pref->{uid}||0,
		 state=>'run',
		 priority=>1,
		 fname=>'fake_process',
		 size=>1,
		 rss=>1,
		 req_hostname=>$pref->{req_hostname},
		 req_pid=>$pref->{req_pid},
		 );
	    push @pids, $proc;
	    #print "PIDINH $pid $proc   $pref->{start} ",time(),"\n";
	}
    }
    return \@pids;
}

package Schedule::Load::FakeReporter;

######################################################################
#### Local process entry

package Schedule::Load::FakeReporter::ProcessTable::Process;
use strict;
use Carp;
use vars qw ($AUTOLOAD);

sub new {
    my ($this, %args) = @_;
    my $class = ref($this) || $this;
    my $self = \%args;
    bless $self, $class;
    return $self;
}

sub AUTOLOAD {
    my $self = shift;
    (my $field = $AUTOLOAD) =~ s/.*://; # Remove package
    if (exists ($self->{$field})) {
	eval "sub $field { return \$_[0]->{$field}; }";
	return $self->{$field};
    } else {
	croak "$self->$field: Unknown ".__PACKAGE__." field $field";
    }
}

sub DESTROY {}

package Schedule::Load::FakeReporter;

######################################################################
#### Package return
1;

######################################################################
__END__

=pod

=head1 NAME

Schedule::Load::FakeReporter - Distributed load reporting daemon

=head1 SYNOPSIS

  use Schedule::Load::Reporter;

  Schedule::Load::Reporter->start(fake=>1);

=head1 DESCRIPTION

L<Schedule::Load::FakeReporter> creates a
L<Schedule::Load::Reporter::ProcessTable> similar to L<Proc::ProcessTable>,
which allows replacing the normal host information with special fixed
information.  This allows the Schedule::Load facilities to be used to
manage other resources, such as laboratory equipment, that has CPU like
status, but cannot locally run slreportd.

Pctcpu is based on the load_limit or if unspecified, each fixed load counts
as 100%.  Pid is the process ID that should be tracked on the current CPU,
if this is not desired, add a pid_track=0 attribute.

See L<Schedule::Load::Reporter> for most accessors.

=head1 DISTRIBUTION

The latest version is available from CPAN and from L<http://www.veripool.org/>.

Copyright 1998-2006 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License or the Perl Artistic License.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<Schedule::Load::Reporter>, L<slreportd>

=cut
