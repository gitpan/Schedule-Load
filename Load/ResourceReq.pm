# See copyright, etc in below POD section.
######################################################################

package Schedule::Load::ResourceReq;
require 5.004;
use Schedule::Load;
use Sys::Hostname;

use strict;
use vars qw($VERSION $AUTOLOAD $Debug);
use Carp;

######################################################################
#### Configuration Section

$VERSION = '3.064';

######################################################################
#### Creators

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = {allow_reserved=>0,	# Passed to Host::host_match
		classes=>[],		# Passed to Host::host_match
		favor_host=>hostname(),
		match_cb=>undef,	# Passed to Host::host_match
		max_jobs=>  -1,		# Whole clump
		jobs_running=>undef,
		rating_cb=>undef,
		@_,};
    bless $self, $class;

    # Add class_ prefix (to be back compatible with prev versions)
    my @classes = ();
    foreach (@{$self->{classes}}) {
	push @classes, (($_ =~ /^class_/)?$_:"class_$_");
    }
    $self->{classes} = \@classes;

    print "new ResourceReq=", Data::Dumper::Dumper ($self) if $Debug;

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

Schedule::Load::ResourceReq - Generate a request for a single resource

=head1 SYNOPSIS

  See Schedule::Load::Schedule

=head1 DESCRIPTION

This package provides a constructor for a request of a single resource.
When scheduling, multiple resource requests may be created and the
scheduler will fill (or deny) all requests in one atomic operation.  This
prevents nasty deadlocks (like the chopsticks deadlock.)

=head1 METHODS

=over 4

=item new (...)

Create a new object with the parameters specified in the following section.

=back

=head1 PARAMETERS

The following parameters are accepted by new(), and are also may be read
via accessor methods.

=over 4

=item allow_reserved

When set, reserved hosts may be scheduled.

=item classes

An array reference of which classes the host must support to allow this job
to be run on that host.  Defaults to [], which allows any host.

=item favor_host

The hostname to try and choose if all is equal, under the presumption that
there are disk access time benefits to doing so.  Defaults to the current host.

=item jobs_running

Current number of jobs the requester is running.  This is compared to max_jobs.

=item keep_idle_cpus

Minimum of cpus that should remain idle before scheduling this job.
Negative fraction indicates that percentage of the clump, for example -0.5
will keep at least 50% of all CPUsidle.  Defaults to 0.

=item match_cb

A string containing a subroutine which will be passed a host reference and
should return true if this host has the necessary properties.  This must
only look at constant properties of the host (IE NOT the current host
loading), as the match results may be cached.  This will be evaluated in a
Safe container, and can do only minimal core functions.  For example:
match_cb=>"sub{return $_[0]->get_undef('memory')>512;}"

=item max_jobs

Maximum number of jobs that can be issued if allow_none is specified in a
scheduler request.  Negative fraction indicates that percentage of the
clump, for example -0.5 will use at most 50% of all CPUs.  Defaults to 100%
of the clump.

=item rating_cb

A string containing a subroutine which will be passed a host reference and
should return a number that is compared against other hosts' ratings to
determine the best host for a new job.  This may include dynamic
information such as instantaneous loading.  A return of zero indicates this
host may not be used.  Ratings closer to zero are better.  Defaults to a
function that includes the load_limit and the cpu percentage free.
Evaluated in a Safe container, and can do only minimal core functions.

=back

=head1 DISTRIBUTION

The latest version is available from CPAN and from L<http://www.veripool.org/>.

Copyright 1998-2011 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License Version 3 or the Perl Artistic License Version 2.0.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<Schedule::Load>, L<Schedule::Load::Hosts>, L<Schedule::Load::Hosts::Host>

=cut
