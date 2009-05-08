# See copyright, etc in below POD section.
######################################################################

package Schedule::Load::Hold;
require 5.004;
use Schedule::Load;
use Sys::Hostname;

use strict;
use vars qw($VERSION $AUTOLOAD);
use Carp;

######################################################################
#### Configuration Section

$VERSION = '3.061';

######################################################################
#### Creators

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = {
	req_hostname=>hostname(),# Host making the request
	req_pid=>$$,		# Process ID making the request
	req_time=>time(),	# When the request was issued
	req_user=>$ENV{USER},	# User name
	req_pri=>0,		# Request priority, maybe negative for better
	hold_key=>undef,	# Key for looking up the request
	hold_load=>1,		# Load to apply to the host
	hold_time=>70,		# Seconds to hold for
	comment=>"",		# Information for printing
	allocated=>undef,	# If set, chooser allocated this hold
	@_,};
    bless $self, $class;
    $self->hold_key or carp "%Warning: No hold_key specified,";
    return $self;
}

sub set_fields {
    my $self = shift;
    my %params = (@_);
    foreach my $key (keys %{$self}) {
	$self->{$key} = $params{$key} if exists $params{$key};
    }
}

######################################################################
#### Special accessors

sub req_age { return (time() - $_[0]->req_time); }

sub compare_pri_time {
    # Sort comparison for ordering requests
    # This must return a consistent order, thus the hold_key is required as part of the compare.
    # For speed this doesn't use accessors - generally don't do this.
    return ($_[0]->{req_pri} <=> $_[1]->{req_pri}
	    || $_[0]->{req_time} <=> $_[1]->{req_time}
	    || $_[0]->{hold_key} cmp $_[1]->{hold_key});
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
######################################################################
1;
__END__

=pod

=head1 NAME

Schedule::Load::Hold - Return hold/wait information

=head1 SYNOPSIS

  See Schedule::Load::Schedule

=head1 DESCRIPTION

This package provides accessors for information about a specific request
that is either waiting for a host, or has obtained a host and is holding it
temporarily.

=head1 ACCESSORS

=over 4

=item allocated

Set by scheduler to indicate this hold has been scheduled resources, versus
a hold that is awaiting further resources to complete.  For informational
printing, not set by user requests.

=item comment

Text comment for printing in reports.

=item hold_key

Key for generating and removing the request via Schedule::Load::Schedule.

=item hold_load

Number of loads to apply, for Schedule::Load::Schedule applications.
Negative will request all resources on that host.

=item hold_time

Number of seconds the hold should apply before deletion.

=item req_age

Computed number of seconds since request was issued.

=item req_hostname

Host the request for holding was issued from.

=item req_pid

Pid the request for holding was issued by.

=item req_pri

Priority of the request, defaults to zero.  Lower is higher priority.

=item req_time

Time the request for holding was issued.  The chooser may move this time
back to correspond to the very first request if the new hold's key matches
a hold issued earlier.  Due to this, hold_keys should be different with
each unique request.

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
