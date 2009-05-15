# See copyright, etc in below POD section.
######################################################################

package Schedule::Load::Reporter::Filesys;
use Schedule::Load qw (:_utils);
use Time::HiRes qw (gettimeofday);
use Filesys::DfPortable qw();
use IO::File;
use strict;
use Carp;
use Sys::Hostname;

our $Debug;

######################################################################
#### Configuration Section

######################################################################
#### Methods

sub new {
    my $class = shift;
    my $self = {_stats => {},
		filesystems => ['/','/local','/'.hostname],
		enabled => 1,
		@_};

    return bless $self, $class;
}

sub stats { return $_[0]->{_stats}; }

sub poll {
    my $self = shift;
    return if !$self->{enabled};

    # In the future we may want to track trends, so could see warnings if filling fast!
    foreach my $fs (@{$self->{filesystems}}) {
	my $df = Filesys::DfPortable::dfportable($fs,1);
	next if !$df;
	my $fsname;
	if ($fs eq '/') {
	    $fsname = 'root';
	} else {
	    ($fsname = $fs) =~ s/[^a-zA-Z0-9]+//g;
	}
	$self->{_stats}{"fs_${fsname}_size"} = $df->{blocks}; # Total space in bytes
	$self->{_stats}{"fs_${fsname}_pct"} = $df->{per};   # Percent full
	# free/avail are approximately calculatable using the above
    }
}

######################################################################
#### Package return
1;
__END__

=pod

=head1 NAME

Schedule::Load::Reporter::Filesys - slreportd filesystem data collector

=head1 SYNOPSIS

  use Schedule::Load::Reporter::Filesys;

  my $n = new Schedule::Load::Reporter::Filesys;
  $n->poll;
  print Dumper($n->stats);

=head1 DESCRIPTION

L<Schedule::Load::Reporter::Filesys> is a plugin for slreportd that
collects filesystem performance statistics for most Linux systems.

=over 4

=item new

Creates a new report object.

=item poll ($now_secs, $now_usecs)

Collects statistics, and scales by the time since the last poll.  Pass in
the current time (this avoids multiple syscalls when there's many plugins).

=item stats

Return an array reference with the statistics.

=back

=head1 DISTRIBUTION

The latest version is available from CPAN and from L<http://www.veripool.org/>.

Copyright 1998-2009 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License Version 3 or the Perl Artistic License Version 2.0.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<Schedule::Load>, L<slreportd>

=cut
