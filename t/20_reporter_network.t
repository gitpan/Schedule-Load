#!/usr/bin/perl -w
# DESCRIPTION: Perl ExtUtils: Type 'make test' to test this package
#
# Copyright 2006-2009 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# Lesser General Public License Version 3 or the Perl Artistic License Version 2.0.

use strict;
use Test;
use Data::Dumper; $Data::Dumper::Indent=1; $Data::Dumper::Sortkeys=1;

BEGIN { plan tests => 5 }
BEGIN { require "t/test_utils.pl"; }

use Schedule::Load::Reporter::Network;
ok(1);

my $report = Schedule::Load::Reporter::Network->new();
ok($report);

$report->poll;
#sleep 1;
$report->poll;
ok($report->stats);
print Dumper($report->stats);

if (!$ENV{VERILATOR_AUTHOR_SITE}) {
    # We might not be on a Linux system with appropriate /proc access
    skip("author only test (harmless)",1);
    skip("author only test (harmless)",1);
} else {
    ok(defined $report->stats->{network_rx_bytes});
    ok(defined $report->stats->{network_tx_bytes});
}
