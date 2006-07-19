# $Id: Safe.pm,v 1.3 2006/07/19 13:54:56 wsnyder Exp $
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

package Schedule::Load::Safe;
require 5.004;

use Safe;

use strict;
use vars qw($VERSION $Debug);
use Carp;

######################################################################
#### Configuration Section

$VERSION = '3.040';

######################################################################
#### Creators

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = {
	_cache => {},
	cache_max_entries => 1000,	# Maximum size of the cache (so we don't run out of memory)
	@_,};
    bless $self, $class;
    return $self;
}

######################################################################
#### Evaluation

sub _cache_check {
    my $self = shift;
    if (keys (%{$self->{_cache}}) > $self->{cache_max_entries}) {
	# For speed, rather then a single entry, delete random ~10% of entries.
	foreach my $key (keys %{$self->{_cache}}) {
	    if (rand(10)<=1.0) {
		delete $self->{_cache}{$key};
	    }
	}
    }
}

sub eval_cb {
    my $self = shift;
    my $subref = shift;
    my @subargs = @_;
    # Call &$subref($subargs) in safe container
    if (ref $subref) {
	return $subref->(@subargs);
    } else {
	if (!exists $self->{_cache}{$subref}) {
	    my $compartment = new Safe;
	    $compartment->permit(qw(:base_core));
	    $@ = "";
	    my $code = $compartment->reval($subref);
	    if ($@ || !$code) {
		print "eval_match: $@: $subargs[0]\n" if $Debug;
		$self->{_cache}{$subref} = undef;
		return undef;
	    
	    }
	    $self->_cache_check();
	    $self->{_cache}{$subref} = $code;
	}
	my $code = $self->{_cache}{$subref};
	return undef if !defined $code;
	my $result = $code->(@subargs);
	if ($Debug && $Debug>1) {   # Try again in non-safe container
	    my $dcode = eval($subref);
	    my $dresult = $dcode->(@subargs);
	    die "%Error: Safe mismatch: '$result' ne '$dresult'\n" if $dresult ne $result;
	}
	return $result;
    }
}

######################################################################
######################################################################
1;
__END__

=pod

=head1 NAME

Schedule::Load::Safe - Evaluate callback in Safe container with caching

=head1 SYNOPSIS

  See Schedule::Load::Schedule

=head1 DESCRIPTION

This package is for internal use of Schedule::Load.  It allows a function
to be defined inside a Safe container, then saved inside a cache for later
use.  This is significantly faster then creating a safe container for each
evaluation.

=head1 DISTRIBUTION

The latest version is available from CPAN and from L<http://www.veripool.com/>.

Copyright 1998-2006 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License or the Perl Artistic License.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<Schedule::Load>

=cut
