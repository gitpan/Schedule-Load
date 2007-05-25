# Schedule::Load::Schedule.pm -- Schedule jobs across a network
# $Id: Schedule.pm 111 2007-05-25 14:40:56Z wsnyder $
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

package Schedule::Load::Schedule;
require 5.004;
require Exporter;
@ISA = qw(Exporter Schedule::Load::Hosts);

use Schedule::Load qw (:_utils);
use Schedule::Load::Hosts;
use Schedule::Load::ResourceReq;
use Sys::Hostname;
use Time::localtime;

use strict;
use vars qw($VERSION $Debug @MoY);
use Carp;

######################################################################
#### Configuration Section

# Other configurable settings.
$Debug = $Schedule::Load::Debug;
$VERSION = '3.051';
@MoY = ('Jan','Feb','Mar','Apr','May','Jun',
	'Jul','Aug','Sep','Oct','Nov','Dec');

######################################################################
#### Globals

######################################################################
#### Creator

sub new {
    @_ >= 1 or croak 'usage: '.__PACKAGE__.'->new ({options})';
    my $proto = shift;
    return $proto->SUPER::new
	( scheduled_hosts => [],
	  @_);
}

######################################################################
#### Constructor

######################################################################
#### Accessors

sub scheduled_hosts {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->scheduled_hosts (perhaps you forgot to check schedule return for undef)';
    return (wantarray ? @{$self->{scheduled_hosts}} : $self->{scheduled_hosts});
}

sub scheduled_hostnames {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->scheduled_hosts (perhaps you forgot to check schedule return for undef)';
    return () if !$self->{scheduled_hosts}[0];
    my @names = map {$_->hostname; } $self->scheduled_hosts;
    return @names;
}

sub hosts_of_class {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts()';
    # DEPRECIATED.  Return all hosts matching given class
    # allow_reserved was ignored in the old implementation...
    return $self->hosts_match (@_, allow_reserved=>1);
}

######################################################################
######################################################################
#### Functions

sub reserve_default_comment {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->reserve_default_comment)';
    return sprintf ("$self->{username} at %02d-%s %02d:%02d",
		    localtime->mday, $MoY[localtime->mon], 
		    localtime->hour, localtime->min),
}

sub reserve {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->reserve)';
    my $params = {
	host=>hostname(),
	uid=>$<,
	comment=>$self->reserve_default_comment(),
	@_,};

    print __PACKAGE__."::reserve($params->{host}, $params->{comment})\n" if $Debug;
    $self->_fetch_if_unfetched();

    my $host = $self->get_host($params->{host});
    ($host) or die "%Error: Host $params->{host} not found, so not reserved\n";
    (!$host->reserved) or die "%Error: Host $params->{host} already reserved by ".$host->reserved."\nrelease this reservation first.\n";
    ($host->reservable) or die "%Error: Host $params->{host} is not reservable\n";

    $self->set_stored(host=>$params->{host},
		      reserved=>$params->{comment},);
    $self->fetch();
    $host = $self->get_host($params->{host});	# Fetch might have new reference
    ($host) or croak "%Error: Host $params->{host} not responding";
    ($host->reserved) or croak "%Error: Host $params->{host} didn't accept reservation";
}

sub release {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts)';
    my $params = {
	host=>hostname(),
	@_,};

    print __PACKAGE__."::release($params->{host})\n" if $Debug;
    $self->_fetch_if_unfetched();

    my $host = $self->get_host($params->{host});
    if (!$host) {
	warn "Note: Host $params->{host} not found, so not released\n";
	return;
    }
    if (!$host->reserved) {
	warn "Note: Host $params->{host} not reserved, so not released\n";
	return;
    }

    $self->set_stored(host=>$params->{host},
		      reserved=>0,);
    $self->fetch();
    $host = $self->get_host($params->{host});	# Fetch might have new reference
    ($host) or croak "%Error: Host $params->{host} not responding";
    (!$host->reserved) or croak "%Error: Host $params->{host} didn't accept release";
}

sub fixed_load {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->fixed_load)';
    my $params = {
	host=>hostname(),
	load=>1,  # Negative for all cpus
	uid=>$<,
	pid=>$$,
	req_hostname=>hostname(),  # Where to do a pid_exists
	#req_pid=>pid,
	@_,};
    $params->{req_pid} ||= $params->{pid};
    print __PACKAGE__."::fixed_load($params->{load})\n" if $Debug;
    $self->_request(_pfreeze( 'report_fwd_fixed_load', $params, $Debug));
}

sub hold_release {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hold_release)';
    my $params = {
	hold_key=>undef,
	@_,};

    print __PACKAGE__."::hold_release($params->{hold_key})\n" if $Debug;
    $self->_request(_pfreeze( 'hold_release', $params, $Debug));
}

######################################################################
######################################################################
#### Scheduling

sub best {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->best';
    my %params = (allow_none=>0,
		  @_);
    print __PACKAGE__."::best()\n" if $Debug;
    # Backward compatible best function, scheduling on one host without
    # need to understand new Hold and ResourceReq structures.

    # Make a hold element with passed params
    my $hold = Schedule::Load::Hold->new(hold_key=>"best",);
    $hold->set_fields (%{$self},%params);
    # Make resource requests with passed params
    my $req = Schedule::Load::ResourceReq->new();
    $req->set_fields (%{$self},%params);
    my $rtn = $self->schedule
	(resources=>[$req],
	 hold=>$hold,
	 allow_none=>1,
	 %params);
    return undef if !$rtn;
    return undef if !$rtn || !$rtn->scheduled_hosts;
    my @hn = $rtn->scheduled_hostnames;
    return $hn[0];
}

sub jobs {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->jobs';
    #** Old depreciated interface
    print __PACKAGE__."::jobs()\n" if $Debug;
    my @names = $self->idle_host_names(@_);
    return ($#names+1);
}

sub schedule {
    my $self = shift;
    my %params = (allow_none=>0,
		  hold=>undef,	# Schedule::Load::Hold reference, undef not to hold
		  resources=>[],# Schedule::Load::ResourceReq reference
		  @_);

    $self->{scheduled_hosts} = [];
    $self->{_schrtn} = undef;
    $params{resources}[0] or croak "%Error: Not passed any resources=>[] to schedule,";

    use Data::Dumper; print "SCHEDULE: ",Dumper(\%params) if $Debug;
    $self->_request(_pfreeze ("schedule", \%params, 0&&$Debug));

    use Data::Dumper; print "RETURN: ",Dumper($self->{_schrtn}) if $Debug;
    (defined $self->{_schrtn}) or die "%Error: Didn't get proper schedule response\n";

    if (!$self->{_schrtn}{best}) {
	return undef;
    } else {
	# Remap the hostnames to references (can't pass refs across a socket!)
	foreach my $hostname (@{$self->{_schrtn}{best}}) {
	    my $host = $self->get_host($hostname);
	    if (!$host) {
		# It's a host that wasn't in our cache....
		print " Gethost $hostname failed, retrying caching\n" if $Debug;
		$self->kill_cache;
		$self->fetch;
		$host = $self->get_host($hostname);
		if (!$host) {
		    print " Gethost $hostname retry failed\n" if $Debug;
		    return undef;  # Next scheduler attempt should make sense of it all...
		}
	    }
	    push @{$self->{scheduled_hosts}}, $host;
	}
    }
    return $self;
}

sub night_hours_p {
    # Return true if working hours
    my $working = ((localtime->hour >= 7 && localtime->hour < 22)
		   && (localtime->wday >= 1 && localtime->wday < 6)); # M-F
    return !$working;
}

######################################################################
######################################################################
#### Changing persistent store's on a host

sub set_stored {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts)';
    my $params = {
	host=>undef,
	#set_const=>undef,	# If true, put into constant rather then stored data
	@_,};

    print __PACKAGE__."::set_stored($params->{host})\n" if $Debug;
    $self->_fetch_if_unfetched();

    my $host = $self->get_host($params->{host});
    ($host) or die "%Error: Host $params->{host} not found, so not set\n";

    $self->_request(_pfreeze( 'report_fwd_set', $params, $Debug));
    $self->fetch();
}

sub _set_host_stored {
    my $self = shift;
    my $host = shift;
    my $var = shift;
    my $value = shift;
}

######################################################################
#### Package return
1;

######################################################################
__END__

=pod

=head1 NAME

Schedule::Load::Schedule - Functions for choosing a host among many

=head1 SYNOPSIS

    use Schedule::Load::Schedule;

    my $scheduler = Schedule::Load::Schedule->fetch();
    print "Best host for a new job: ", $scheduler->best();

=head1 DESCRIPTION

This package will allow the most lightly loaded host to be chosen for new
jobs across many machines across a entire network.

It is also a superclass of Schedule::Load::Hosts, so any functions that
work for that module also work here.

=head1 METHODS

=over 4 

=item best (...)

Returns the hostname of the best host in the network for a single new job.
Parameters may be parameters specified in this class, Schedule::Load::Hold,
or Schedule::Load::ResourceReq.  Those packages must be used individually
if multiple resources need to be scheduled simultaneously.

=item fixed_load (load=>load_value, [pid=>$$], [host=>localhost], [req_pid=>$$, req_hostname=>localhost])

Sets the current process and all children as always having at least the
load value specified.  This prevents under-counting CPU utilization when a
large batch job is running which is just paused in the short term to do
disk IO or sleep.  Requests to fake reporters (resources not associated
with a CPU) may specify req_pid and req_hostname which are the PID and
hostname that must continue to exist for the fixed_load to remain in place.

=item hold_release (hold_key=>key)

Releases the temporary hold placed with the best function.

=item hosts_of_class (class=>name)

Depreciated, and to be removed in later releases.  Use hosts_match instead.

=item jobs (...)

Returns the maximum number of jobs suggested for the given scheduling
parameters.  Presumably this will be used to spawn parallel jobs for one
given user, such as the C<make -j> command.  Jobs() takes the same
arguments as best(), in addition to the max_jobs parameter.

=item release (host=>hostname)

Releases the machine from exclusive use of any user.  The user doing the
release does not have to be the same user that reserved the host.

=item reserve (host=>hostname, [comment=>comment])

Reserves the machine for exclusive use of the current user.  The host
chosen must have the reservable flag set.  C<rschedule hosts> will show
the host as reserved, along with the provided comment.

=item schedule (hold=>Schedule::Load::Hold ref, resources=>[], [allow_none=>1])

Schedules the passed list of Schedule::Load::ResourceReq resources, and
holds them using the passed hold key.  If allow_none is set and the loading
is too high, does not schedule any resources.  Returns a object reference
to use with scheduled_hosts, or undef if no resources available.

=item scheduled_hosts

Returns a list of Schedule::Load::Host objects that were scheduled using
the last schedule() call.

=item set_stored (host=>hostname, [set_const=>1], [key=>value])

Set a key/value parameter on the persistent storage on the remote server,
such as if a class is allowed on that host.  With const=>1, don't make it
persist, but make it look like the daemon was started with that option;
when the daemon restarts the information will be lost.

=back

=head1 PARAMETERS

Parameters for the new and fetch calls are shown in
L<Schedule::Load::Hosts>.

=over 4

=item allow_none

If allow_none is true, if there is less then a free CPU across the entire
network, then no cpu will be chosen.  This is useful for programs that can
dynamically adjust their outstanding job count.  (Presumably you would only
set allow_none if you already have one job running, or you can get
live-locked out of getting anything!)

=back

=head1 DISTRIBUTION

The latest version is available from CPAN and from L<http://www.veripool.com/>.

Copyright 1998-2006 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License or the Perl Artistic License.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<Schedule::Load>, L<Schedule::Load::Hosts>, L<rschedule>

=cut
