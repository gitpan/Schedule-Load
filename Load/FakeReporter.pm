# Schedule::Load::FakeReporter.pm -- distributed lock handler
# $Id: FakeReporter.pm,v 1.8 2002/08/30 14:59:10 wsnyder Exp $
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

package Schedule::Load::FakeReporter;
require 5.004;
@ISA = qw(Schedule::Load::Reporter);

use strict;
use vars qw($VERSION $Debug
	    );
use Carp;
use POSIX;

######################################################################
#### Configuration Section

# Other configurable settings.
$Debug = $Schedule::Load::Debug;

$VERSION = '2.100';

######################################################################
#### Globals

# This is the self elemenst sent over the socket:
# $self->{const}{config_element_name} = value	# Such as things from ENV
# $self->{load}{load_element} = value		# Overall loading info
# $self->{proc}{process#}{proc_element} = value	# Per process info

######################################################################
#### Creator

#Inherited:
sub start {
    my $proto = shift;
    my $class = ref($proto) || $proto;

    my $self = $proto->SUPER::start(@_);
    bless $self, $class;
}

######################################################################
#### Accessors

sub pt {
    my $self = shift;
    if (!$self->{pt}) {
	$self->{pt} = Schedule::Load::FakeReporter::ProcessTable
	    ->new (reportref=>$self);
    }
    return $self->{pt};
}

######################################################################
#### Local process table

package Schedule::Load::FakeReporter::ProcessTable;
use vars qw (@ISA);
#Same functions as: @ISA = qw(Proc::ProcessTable);
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
	if ($pid_track && local_pid_doesnt_exist($pid)) {
	    # Process being tracked died.  fill_dynamic will delete the hash element 
	    return;
	}
	$pref->{start} ||= time();
	my $proc = Schedule::Load::FakeReporter::ProcessTable::Process->new
	    (pid=>$pid,
	     ppid=>0,
	     pctcpu=>100*int(($pref->{fixed_load}||1)/ $load_limit),
	     utime=>0, stime=>0,
	     start=>$pref->{start},
	     time=>time()-$pref->{start},
	     uid=>$pref->{uid}||0,
	     state=>'run',
	     priority=>1,
	     fname=>'fake_process',
	     size=>1,
	     );
	push @pids, $proc;
	#print "PIDINH $pid $proc\n";
    }
    return \@pids;
}

#### Utilities

sub local_pid_doesnt_exist {
    my $result = local_pid_exists(@_);
    # Return 0 if a pid exists, 1 if not, undef (or second argument) if unknown
    return undef if !defined $result;
    return !$result;
}

sub local_pid_exists {
    my $pid = shift;
    # Return 1 if a pid exists, 0 if not, undef (or second argument) if unknown
    # We can't just call kill, because if there's a different user running the
    # process, we'll get an error instead of a result.
    $! = undef;
    my $exists = (kill (0,$pid))?1:0;
    if ($!) {
	$exists = undef;
	$exists = 0 if $! == POSIX::ESRCH;
    }
    return $exists;
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
    return if $field eq "DESTROY";
  
    if (exists ($self->{$field})) {
	eval "sub $field { my \$self=shift; return \$self->{$field}; }";
	return $self->{$field};
    } else {
	croak "$self->$field: Unknown ".__PACKAGE__." field $field";
    }
}

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

  use Schedule::Load::FakeReporter;

  Schedule::Load::FakeReporter->start();

=head1 DESCRIPTION

C<Schedule::Load::FakeReporter> creates a C<Schedule::Load::Reporter>
derrived class, which allows replacing the normal host information with
special fixed information.  This allows the Schedule::Load facilities to be
used to manage other resources, such as labratory equipment, that has CPU
like status, but cannot locally run slreportd.

Pctcpu is based on the load_limit or if unspecified, each fixed load counts
as 100%.  Pid is the process ID that should be tracked on the current CPU,
if this is not desired, add a pid_track=0 attribute.


See C<Schedule::Load::Reporter> for most accessors.

=head1 PARAMETERS

=over 4

=back

=head1 SEE ALSO

C<Schedule::Load::Reporter>, C<slreportd>

=head1 DISTRIBUTION

This package is distributed via CPAN.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=cut
