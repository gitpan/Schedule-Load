# Schedule::Load::Hosts::Host.pm -- Loading information about a host
# $Id: Host.pm,v 1.28 2003/04/15 15:00:07 wsnyder Exp $
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

package Schedule::Load::Hosts::Host;
require 5.004;
require Exporter;
require AutoLoader;
@ISA = qw(Exporter AutoLoader);

use Schedule::Load qw(_min _max);
use Schedule::Load::Hosts::Proc;

use Safe;
use Carp;
use strict;
use vars qw($VERSION $AUTOLOAD $Debug);

######################################################################
#### Configuration Section

# Other configurable settings.
$VERSION = '2.104';

######################################################################
#### Globals

$Debug = $Schedule::Load::Debug;

######################################################################
#### Special status

sub fields {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->hosts)';
    my @keys = keys %{$self->{const}};
    push @keys, keys %{$self->{stored}};
    push @keys, keys %{$self->{dynamic}};
    return (grep {$_ ne "procs"} @keys);
}

sub exists {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->get(field))';
    my $field = shift;
    return (exists ($self->{dynamic}{$field})
	    || exists ($self->{stored}{$field})
	    || exists ($self->{const}{$field}));
}

sub get {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->get(field))';
    my $field = shift;
    # Always look at dynamic info first, there might be a override of a const
    if (exists ($self->{dynamic}{$field})) {
	return $self->{dynamic}{$field};
    } elsif (exists ($self->{stored}{$field})) {
	return $self->{stored}{$field};
    } elsif (exists ($self->{const}{$field})) {
	return $self->{const}{$field};
    } else {
	croak __PACKAGE__.'->get($field): Unknown field';
    }
}

sub get_undef {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->get(field))';
    my $field = shift;
    # Always look at dynamic info first, there might be a override of a const
    if (exists ($self->{dynamic}{$field})) {
	return $self->{dynamic}{$field};
    } elsif (exists ($self->{stored}{$field})) {
	return $self->{stored}{$field};
    } elsif (exists ($self->{const}{$field})) {
	return $self->{const}{$field};
    } else {
	return undef;
    }
}

######################################################################
#### Matching

sub classes_match {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->classes_match(classesref))';
    my $classesref = shift;
    return 1 if !defined $classesref || !defined $classesref->[0];  # Null reference means match everything
    (ref($classesref)) or croak 'usage: '.__PACKAGE__.'->classes_match(field, classesref))';
    foreach (@{$classesref}) {
	return 1 if get_undef($self, $_);
    }
    return 0;
}

sub eval_match {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->eval_match(subroutine)';
    my $subref = shift;
    return 1 if !defined $subref;  # Null reference means match everything
    return $self->_eval_generic_cb($subref);
}

sub _eval_generic_cb {
    my $self = shift;
    my $subref = shift;
    # Call &$subref($self) in safe container
    if (ref $subref) {
	return $subref->($self);
    } else {
	my $compartment = new Safe;
	$compartment->permit(qw(:base_core));
	$@ = "";
	@_ = ($self);  # Arguments to pass to reval
	my $code = $compartment->reval($subref);
	if ($@ || !$code) {
	    print "eval_match: $@: $subref\n" if $Debug;
	    return 0;
	}
	my $result = $code->($self);
	if ($Debug) {   # Try again in non-safe container
	    @_ = ($self);  # Arguments to pass to reval
	    my $dcode = eval($subref);
	    my $dresult = $dcode->($self);
	    die "%Error: Safe mismatch: '$result' ne '$dresult'\n" if $dresult ne $result;
	}
	return $result;
    }
}

######################################################################
#### Special accessors

sub top_processes {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->key(key))';
    my @keys = (values %{$self->{dynamic}{proc}});
    grep {bless $_, 'Schedule::Load::Hosts::Proc'} @keys;
    #print "TOP PROC @keys\n";
    return (wantarray ? @keys : \@keys);
}

sub rating_cb {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->key(key))';
    # How fast can we process a single job?
    # 0 indicates can't load this host
    # closer to 0 are the best ratings (as 'bad' is open-ended)
    if ($self->get_undef('load_limit')
	&& $self->load_limit <= $self->adj_load) {
	# Illegal to load this host more
	return 0;
    }

    my $rate = 1e9;
    # Multiply badness by cpu loading
    # Scale it to be between .8 and 1.0, else a large number of inactive jobs would
    # result in a very good rating, which would make that machine always be picked.
    $rate *= ((($self->total_pctcpu+1)/100) * 0.2 + 0.8);
    # Multiply that by number of jobs
    $rate *= ($self->adj_load+1);
    # Discount by cpus & frequency
    $rate /= $self->cpus;
    $rate /= $self->max_clock * 0.4;   # 1 free cpu at 300Mhz beat 50% of a 600 Mhz cpu

    #printf "%f * (%d+%d+1) / %f / %f = %f\n", ($self->total_pctcpu+1), $self->report_load, $self->adj_load, $self->cpus, $self->max_clock, $rate if $Debug;
    return 0 if $rate<=0;
    $rate = log($rate);		# Make a more readable number
    $rate += $self->rating_adder() if $self->get_undef('rating_adder');
    return $rate;
}

sub rating {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->rating(subroutine)';
    my $subref = shift;
    return $self->rating_cb() if !defined $subref;  # Null reference means default callback
    return $self->_eval_generic_cb($subref);
}

sub rating_text {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->rating(subroutine)';
    return "inf" if $self->reserved;
    return "inf" if !$self->rating;
    return sprintf("%4.2f", $self->rating);
}

######################################################################
#### Accessors

sub AUTOLOAD {
    my $self = shift;
    my $type = ref($self) or croak "$self is not an ".__PACKAGE__." object";
    
    (my $field = $AUTOLOAD) =~ s/.*://; # Remove package
    return if $field eq "DESTROY";
  
    if (exists ($self->{dynamic}{$field})) {
	# Dynamic variables stay dynamic
	eval "sub $field { return \$_[0]->{dynamic}{$field}; }";
	return $self->{dynamic}{$field};
    } elsif (exists ($self->{stored}{$field})) {
	# Stored variables can move to/from const variables
	eval "sub $field { return (exists \$_[0]->{stored}{$field} "
	    ."? \$_[0]->{stored}{$field} : \$_[0]->{const}{$field}); }";
	return $self->{stored}{$field};
    } elsif (exists ($self->{const}{$field})) {
	eval "sub $field { return (exists \$_[0]->{stored}{$field} "
	    ."? \$_[0]->{stored}{$field} : \$_[0]->{const}{$field}); }";
	return $self->{const}{$field};
    } else {
	croak "$type->$field: Unknown ".__PACKAGE__." field $field";
    }
}

######################################################################
######################################################################
#### Package return
1;

######################################################################
__END__

=pod

=head1 NAME

Schedule::Load::Hosts::Host - Return information about a host

=head1 SYNOPSIS

  See Schedule::Load::Hosts

=head1 DESCRIPTION

This package provides accessors for information about a specific
host obtained via the Schedule::Load::Host package.

=over 4 

=item classes_match

Passed an array reference.  Returns true if this host's class matches any
class in the array referenced.

=item eval_match

Passed a subroutine reference that takes a single argument of a host
reference.  Returns true if the subroutine returns true.  It may also be
passed a string which forms a subroutine ("sub { my $self = shift; ....}"),
in which case the string will be evaluated in a safe container.

=item fields

Returns all information fields for this host.

=item exists (key)

Returns if a specific field exists for this host.

=item get (key)

Returns the value of a specific field for this host.

=back

=head1 ACCESSORS

A accessor exists for each field returned by the fields() call.  Typical elements
are described below.

=over 4 

=item top_processes

Returns a reference to a list of top process objects,
C<Schedule::Load::Hosts::Proc> to access the information for each process.
In an array context, returns a list; In a a scalar context, returns a
reference to a list.

=item archname

Architecture name from Perl build.

=item cpus

Number of CPUs.

=item hostname

Name of the host.

=item max_clock

Maximum clock frequency.

=item load_limit

Limit on the loading that a machine can bear, often set to the number
of CPUs to not allow overloading of a machine.  Undefined if no limit.

=item osname

Operating system name from Perl build.

=item reservable

If true, this host may be reserved for exclusive use by a user.

=item reserved

If true, this host is reserved, and this field contains a username and
start time comment.

=item systype

System type from Perl build.

=item total_load

Total number of processes in run or on processor state.

=item adj_load

Total number of processes in run or on processor state, adjusted for any
jobs that have a specific fixed_load or hold time.  This is the load used
for picking hosts.

=item total_pctcpu

Total CPU percentage used by all processes.

=back

=head1 SEE ALSO

C<Schedule::Load>, C<Schedule::Load::Hosts>, C<Schedule::Load::Hosts::Proc>

=head1 DISTRIBUTION

The latest version is available from CPAN.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=cut
