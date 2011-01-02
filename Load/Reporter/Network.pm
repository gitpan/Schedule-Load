# See copyright, etc in below POD section.
######################################################################

package Schedule::Load::Reporter::Network;
use Schedule::Load qw (:_utils);
use Time::HiRes qw (gettimeofday);
use IO::File;
use strict;
use Carp;

our $Debug;

######################################################################
#### Configuration Section

our $_Proc_Filename = "/proc/net/dev";

######################################################################
#### Methods

sub new {
    my $class = shift;
    my $self = {_stats => {},
		skip_device_regexp => qr/^lo$/,	# Skip loopback device
		enabled => (-e $_Proc_Filename),
		@_};

    return bless $self, $class;
}

sub stats { return $_[0]->{_stats}; }

sub poll {
    my $self = shift;
    my $now_sec = shift; my $now_usec = shift;
    if (!$now_sec) { ($now_sec, $now_usec) = gettimeofday(); }
    return if !$self->{enabled};

    my @stats = $self->_net_raw_stats();

    if (my $last = $self->{_net_last_stats}) {
	my $delt = ($now_sec - $self->{_net_last_sec})
	    + ($now_usec - $self->{_net_last_usec})*1e-6;
	$self->{_stats}{network_rx_bytes}   = _diff($stats[0], $last->[0],$delt);
	$self->{_stats}{network_rx_packets} = _diff($stats[1], $last->[1],$delt);
	$self->{_stats}{network_tx_bytes}   = _diff($stats[2], $last->[2],$delt);
	$self->{_stats}{network_tx_packets} = _diff($stats[3], $last->[3],$delt);
    }
    $self->{_net_last_stats} = \@stats;
    $self->{_net_last_sec} = $now_sec;
    $self->{_net_last_usec} = $now_usec;
}

sub _net_raw_stats {
    my $self = shift;
    my $fh = IO::File->new("<$_Proc_Filename");
    if (!$fh) {
	#warn "%Warning: $! $_Proc_Filename," if $Debug;
	return undef;
    }

    my @data;
    while (defined(my $line = $fh->getline)) {
	if ($line =~ /:/) {
	    next if $line =~ /^\s+lo:/;  # Ignore loopback
	    $line =~ s/^ +//;
	    my @linedata = split(/[ \t:]+/,$line);
	    next if $linedata[0] =~ /$self->{skip_device_regexp}/;

	    $data[0] += $linedata[1];  # bytes rx
	    $data[1] += $linedata[2];  # packets rx
	    $data[2] += $linedata[9];  # bytes tx
	    $data[3] += $linedata[10];  # packets tx
	}
    }
    $fh->close();
    #print "_net_raw_stats ",join('  ',@data),"\n" if $Debug;
    return @data;
}

#######################################################################

sub _diff {
    my $new = shift;
    my $old = shift;
    my $delt = shift;
    # Note statistics CAN WRAP!
    return undef if !defined $new;
    if ($old > $new) { $new += 4*1024*1024*1024; }
    return ($new - $old)/$delt;
}

######################################################################
#### Package return
1;
__END__

=pod

=head1 NAME

Schedule::Load::Reporter::Network - slreportd network data collector

=head1 SYNOPSIS

  use Schedule::Load::Reporter::Network;

  my $n = new Schedule::Load::Reporter::Network;
  $n->poll;
  print Dumper($n->stats);

=head1 DESCRIPTION

L<Schedule::Load::Reporter::Network> is a plugin for slreportd that collects
network statistics from Linux 2.16 machines.

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

Copyright 1998-2011 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License Version 3 or the Perl Artistic License Version 2.0.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<Schedule::Load>, L<slreportd>

=cut
