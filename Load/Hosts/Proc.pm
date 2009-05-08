# Schedule::Load::Hosts::Proc.pm -- Process information
# See copyright, etc in below POD section.
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
$VERSION = '3.061';

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
    return $self->format_hhmm($self->time);
}

sub format_hhmm {
    my $self = shift;
    my $runtime = shift;
    if ($runtime >= 2*3600) {
	return sprintf "%3.1fH", int($runtime/360)/10;
    } else {
	return sprintf "%3d:%02d", int($runtime/60), $runtime%60;
    }
}

######################################################################
#### Accessors

sub AUTOLOAD {
    my $self = shift;
    my $type = ref($self) or croak "$self is not an ".__PACKAGE__." object";

    (my $field = $AUTOLOAD) =~ s/.*://; # Remove package
    if (exists ($self->{$field})) {
	eval "sub $field { return \$_[0]->{$field}; }";
	return $self->{$field};
    } else {
	croak "$type->$field: Unknown ".__PACKAGE__." field $field";
    }
}
sub DESTROY {}

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
elements are described below.  All fields that L<Proc::ProcessTable>
supports are also accessible.

=over 4

=item nice0

Nice value with 0 being normal and 19 maximum nice.

=item time_hhmm

Returns the runtime of the process in mmm:ss or hh.hH format, whichever is
appropriate.

=item username

Texual user name running this process.

=back

=head1 DISTRIBUTION

The latest version is available from CPAN and from L<http://www.veripool.org/>.

Copyright 1998-2009 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License Version 3 or the Perl Artistic License Version 2.0.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<Schedule::Load>, L<Schedule::Load::Hosts>, L<Schedule::Load::Hosts::Host>

=cut
