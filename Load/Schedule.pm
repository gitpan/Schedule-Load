# Schedule::Load::Schedule.pm -- Schedule jobs across a network
# $Id: Schedule.pm,v 1.10 2000/11/03 20:53:32 wsnyder Exp $
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

package Schedule::Load::Schedule;
require 5.004;
require Exporter;
@ISA = qw(Exporter Schedule::Load::Hosts);

use Schedule::Load qw (:_utils);
use Schedule::Load::Hosts;
use Sys::Hostname;
use Time::localtime;

use strict;
use vars qw($VERSION $Debug @MoY);
use Carp;

######################################################################
#### Configuration Section

# Other configurable settings.
$Debug = $Schedule::Load::Debug;
$VERSION = '1.3';
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
	( night_hours_cb => \&night_hours_p,
	  favor_host => hostname(),
	  hold_time => 60,	# secs
	  @_);
}

######################################################################
#### Constructor

######################################################################
#### Accessors

sub hosts_of_class {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts()';
    my $schparams = $self->_scheduler_params (@_);
    # Return all hosts matching given class
    my @keys = ();
    foreach (@{$self->hosts}) {
	push @keys, $_ if $_->classes_match ($schparams->{classes});
    }
    return (wantarray ? @keys : \@keys);
}

######################################################################
######################################################################
#### Functions

sub reserve {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts)';
    my $params = {
	host=>hostname(),
	comment=>sprintf ("$self->{username} at %02d-%s %02d:%02d",
			  localtime->mday, $MoY[localtime->mon], 
			  localtime->hour, localtime->min),
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
    (!$host->reserved) or croak "%Error: Host $params->{host} didn't accept release";
}

sub fixed_load {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->fixed_load)';
    my $params = {
	host=>hostname(),
	load=>1,
	pid=>$$,
	@_,};

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
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->best)';
    my $schparams = $self->_scheduler_params (@_);

    print __PACKAGE__."::best()\n" if $Debug;
    $self->_schedule_and_get ($schparams);
    return ($self->{_best}{best});
}

sub jobs {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->jobs)';
    my $schparams = $self->_scheduler_params (@_);

    print __PACKAGE__."::jobs()\n" if $Debug;
    $self->_schedule_and_get ($schparams);
    return ($self->{_best}{jobs});
}

sub _schedule_and_get {
    my $self = shift;
    my $schparams = shift;

    $self->{_best} = {};
    $self->_request(_pfreeze ("schedule", $schparams, 0&&$Debug));
    (defined $self->{_best}{jobs}) or die "%Error: Didn't get proper schedule response\n";
}

sub night_hours_p {
    # Return true if working hours
    my $working = ((localtime->hour >= 6 && localtime->hour < 22)
		   && (localtime->wday >= 1 && localtime->wday < 6));
    return !$working;
}

sub _scheduler_params {
    my $self = shift;

    my $is_night = (&{$self->{night_hours_cb}} ($self));
    my $schparams = { classes=>[],
		      allow_none=>0,
		      favor_host=>$self->{favor_host},
		      hold_time=> $self->{hold_time},
		      hold_key=>  undef,
		      max_jobs=>  ($is_night ? -1  : 6 ),
		      @_ };
    # Take a ref to list of classes and add class_ and any night time options
    # Return ref to hash with scheduler options: classes and is_night

    my @classes = ();
    foreach (@{$schparams->{classes}}) {
	$_ = "class_$_" if $_ !~ /^class_/;
	push @classes, $_;
	push @classes, $_ . "_night" if $is_night && ($_ !~ /_night$/);
    }
    $schparams->{classes} = \@classes;
    print "schparams=", Data::Dumper::Dumper ($schparams) if $Debug;
    return $schparams;
}

#    $self->_request("get const load proc\n");

######################################################################
######################################################################
#### Changing persistant store's on a host

sub set_stored {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts)';
    my $params = {
	host=>undef,
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

This package will allow the most lightly loaded host to be choosen for new
jobs across many machines across a entire network.

It is also a superclass of Schedule::Load::Hosts, so any functions that
work for that module also work here.

=over 4 

=item best (...)

Returns the hostname of the best host in the network for a new job.

=over 4

=item allow_none

If allow_none is true, if there is less then a free CPU across the entire
network, then no cpu will be choosen.  This is useful for programs that can
dynamically adjust their outstanding job count.  (Presumably you would only
set allow_none if you already have one job running, or you can get
livelocked out of getting anything!)

=item classes

An array reference of which classes the host must support to allow this job
to be run on that host.  Defaults to [], which allows any host.

=item favor_host

The hostname to try and choose if all is equal, under the presumption that
there are disk access time benefits to doing so.  Defaults to the current host.

=item hold_key

A hold key will reserve a job slot on the choosen CPU until a release_hold
function is called.  This prevents overscheduling a host due to the delay
between choosing a host with a light load and starting the job on it which
rases the CPU load of that choosen host.

=item hold_time

Number of seconds to allow the hold to remain before being removed
automatically.

=back

=item fixed_load (load=>load_value, [pid=>$$], [host=>localhost])

Sets the current process and all children as always having at least the
load value specified.  This prevents undercounting CPU utilization when a
large batch job is running which is just paused in the short term to do
disk IO or sleep.

=item hold_release (hold_key=>key)

Releases the temporary hold placed with the best function.

=item hosts_of_class (class=>name)

Returns C<Schedule::Load::Hosts::Host> objects for every host that matches
the given class.

=item jobs (...)

Returns the maximum number of jobs suggested for the given scheduling
parameters.  Presumably this will be used to spawn parallel jobs for one
given user, such as the C<make -j> command.  Jobs() takes the same
arguments as best(), in addition to:

=over 4

=item max_jobs

Maximum number of jobs that jobs() can return.  Defaults to 6 jobs during
the day, unlimited at night.

=back

=item release (host=>hostname)

Releases the machine from exclusive use of any user.  The user doing the
release does not have to be the same user that reserved the host.

=item reserve (host=>hostname, [comment=>comment])

Reserves the machine for exclusive use of the current user.  The host
choosen must have the reservable flag set.  C<rschedule hosts> will show
the host as reserved, along with the provided comment.

=back

=head1 PARAMETERS

Parameters for the new and fetch calls are shown in
C<Schedule::Load::Hosts>.

=item night_hours_cb

Reference to Function for determining if this is night time, defaults to
M-F 6am-10pm.  When it is nighttime hours, every class passed to the best
option has a new class with _night appended.

=over 4

=back

=head1 SEE ALSO

C<Schedule::Load>, C<Schedule::Load::Hosts>, C<rschedule>

=head1 DISTRIBUTION

The latest version is available from CPAN.

=head1 AUTHORS

Wilson Snyder <wsnyder@world.std.com>

=cut
