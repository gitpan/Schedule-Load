# Schedule::Load::Hosts::Proc.pm -- Process information
# $Id: Proc.pm,v 1.3 2000/01/17 17:49:36 wsnyder Exp $
######################################################################
#
# This program is Copyright 2000 by Wilson Snyder.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public Load
# as published by the Free Software Foundation; either version 2
# of the Load, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public Load for more details.
# 
# If you do not have a copy of the GNU General Public Load write to
# the Free Software Foundation, Inc., 675 Mass Ave, Cambridge, 
# MA 02139, USA.
######################################################################

package Schedule::Load::Hosts::Proc;
require 5.004;
require Exporter;
require AutoLoader;
@ISA = qw(Exporter AutoLoader);

use Schedule::Load;

use strict;
use vars qw($VERSION $AUTOLOAD);
use Carp;

######################################################################
#### Configuration Section

# Other configurable settings.
$VERSION = $Schedule::Load::VERSION;

######################################################################
#### Globals

######################################################################
#### Special accessors

sub fields {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->hosts)';
    return (keys %{$self});
}

sub exists {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->get(field))';
    my $field = shift;
    return (exists ($self->{$field}));
}

sub get {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->get(field))';
    my $field = shift;
    if (exists ($self->{$field})) {
	return $self->{$field};
    } else {
	croak __PACKAGE__.'->get($field): Unknown field';
    }
}

sub time_hhmm {
    my $self = shift; ($self && ref($self)) or croak 'usage: '.__PACKAGE__.'->get(field))';
    return undef if (!defined $self->{time});
    my $runtime = $self->time;
    if ($runtime >= 2*3600) {
	$runtime = sprintf "%3.1fH", int($runtime/360)/10;
    } else {
	$runtime = sprintf "%3d:%02d", int($runtime/60), $runtime%60;
    }
    return $runtime;
}

######################################################################
#### Accessors

sub AUTOLOAD {
    my $self = shift;
    my $type = ref($self) or croak "$self is not an ".__PACKAGE__." object";
    
    (my $field = $AUTOLOAD) =~ s/.*://; # Remove package
    return if $field eq "DESTROY";
  
    if (exists ($self->{$field})) {
	eval "sub $field { my \$self=shift; return \$self->{$field}; }";
	return $self->{$field};
    } else {
	croak "$type->$field: Unknown ".__PACKAGE__." field $field";
    }
}

######################################################################
#### Package return
1;

######################################################################
__END__

=pod

=head1 NAME

Schedule::Load::Hosts::Proc - Return process information

=head1 SYNOPSIS

  See Schedule::Load::Hosts

=head1 DESCRIPTION

This package provides accessors for information about a specific
process obtained via the Schedule::Load::Hosts package.

=over 4 

=item fields

Returns all information fields for this process.

=item exists (key)

Returns true if a specific field exists for this process.

=item get (key)

Returns the value of a specific field for this process.

=back

=head1 ACCESSORS

A accessor exists for each field returned by the fields() call.  Typical
elements are described below.  All fields that C<Proc::ProcessTable>
supports are also included here.

=over 4 

=item nice0

Nice value with 0 being normal and 19 maximum nice.

=item time_hhmm

Returns the runtime of the process in mmm:ss or hh.hH format, whichever is
appropriate.

=item username

Texual user name running this process.

=back

=head1 SEE ALSO

C<Schedule::Load>, C<Schedule::Load::Hosts>, C<Schedule::Load::Hosts::Host>

=head1 DISTRIBUTION

The latest version is available from CPAN.

=head1 AUTHORS

Wilson Snyder <wsnyder@world.std.com>

=cut
