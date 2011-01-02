# See copyright, etc in below POD section.
######################################################################

package Schedule::Load::Reporter::Disk;
use Schedule::Load qw (:_utils);
use Time::HiRes qw (gettimeofday);
use IO::File;
use strict;
use Carp;

our $Debug;

######################################################################
#### Configuration Section

our $_Proc_Filename = "/proc/diskstats";

######################################################################
#### Methods

sub new {
    my $class = shift;
    my $self = {_stats => {},
		device_regexp => qr/^sd[a-z]$/,	# Disks, but not partitions of disks
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

    my @stats = $self->_block_raw_stats();

    if (my $last = $self->{_block_last_stats}) {
	my $delt = ($now_sec - $self->{_block_last_sec})
	    + ($now_usec - $self->{_block_last_usec})*1e-6;
	# All normalized to per second
	$self->{_stats}{disk_rd_num}	= _diff($stats[0], $last->[0], $delt);	# Num reads
	#$self->{_stats}{disk_rd_merged}	= _diff($stats[1], $last->[1], $delt);	# Reads merged
	$self->{_stats}{disk_rd_bytes}	= _diff($stats[2], $last->[2], $delt);	# Bytes read
	$self->{_stats}{disk_rd_sec}	= _diff($stats[3], $last->[3], $delt);	# Seconds reading
	$self->{_stats}{disk_wr_num}	= _diff($stats[4], $last->[4], $delt);	# Num writes
	#$self->{_stats}{disk_wr_merged}	= _diff($stats[5], $last->[5], $delt);	# Writes merged
	$self->{_stats}{disk_wr_bytes}	= _diff($stats[6], $last->[6], $delt);	# Bytes written
	$self->{_stats}{disk_wr_sec}	= _diff($stats[7], $last->[7], $delt);	# Seconds writing
        $self->{_stats}{disk_inprog_num}	= _diff($stats[8], $last->[8], $delt);	# IOs in progress (goes to 0)
        #$self->{_stats}{disk_io_ms}	= _diff($stats[9], $last->[9], $delt);	# Seconds doing io (goes to 0)
        #$self->{_stats}{disk_io_ms_weighted} = _diff($stats[10],$last->[10],$delt);	# Weighted seconds (goes to 0)
    }
    $self->{_block_last_stats} = \@stats;
    $self->{_block_last_sec} = $now_sec;
    $self->{_block_last_usec} = $now_usec;
}

sub _block_raw_stats {
    my $self = shift;
    # For nfs: /proc/self/mountstats
    # /sys/block is 3x faster than reading /proc/diskstats
    # but we often have >3 disks to do....

    my $fh = IO::File->new("<$_Proc_Filename");
    if (!$fh) {
	warn "%Warning: $! $_Proc_Filename," if $Debug;
	return undef;
    }

    my @data;
    while (defined(my $line = $fh->getline)) {
	$line =~ s/^ +//;
	my @linedata = split(/[ \t:]+/,$line);
	next if $linedata[2] !~ /$self->{device_regexp}/;
	#use Data::Dumper; print "LD ",Dumper(\@linedata),"\n";

	$data[0] += $linedata[3];	# Num reads
	#$data[1] += $linedata[4];	# Reads merged
	$data[2] += $linedata[5]*512;	# Sectors read (512 bytes each)
	$data[3] += $linedata[6]*1000;	# Milliseconds reading
	$data[4] += $linedata[7];	# Num writes
	#$data[5] += $linedata[8];	# Writes merged
	$data[6] += $linedata[9]*512;	# Sectors written (512 bytes each)
	$data[7] += $linedata[10]*1000;	# Milliseconds writing
        $data[8] += $linedata[11];	# IOs in progress (goes to 0)
        #$data[9] += $linedata[12]*1000;# Millisec doing io (goes to 0)
        #$data[10]+= $linedata[13]*1000;# Weighted milliseconds (goes to 0)
    }
    $fh->close();
    #print "_block_raw_stats ",join('  ',@data),"\n" if $Debug;
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

Schedule::Load::Reporter::Disk - slreportd disk data collector

=head1 SYNOPSIS

  use Schedule::Load::Reporter::Disk;

  my $n = new Schedule::Load::Reporter::Disk;
  $n->poll;
  print Dumper($n->stats);

=head1 DESCRIPTION

L<Schedule::Load::Reporter::Disk> is a plugin for slreportd that collects
disk performance statistics from Linux 2.16 machines.

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
