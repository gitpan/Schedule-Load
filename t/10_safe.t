#!/usr/bin/perl -w
# DESCRIPTION: Perl ExtUtils: Type 'make test' to test this package
#
# Copyright 2006-2006 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# General Public License or the Perl Artistic License.

use Time::HiRes qw (gettimeofday);
use strict;
use Test;

BEGIN { plan tests => 10 }
BEGIN { require "t/test_utils.pl"; }

$Schedule::Load::Safe::Debug = 1;

my $subself = { one=>1, two=>2, };

use Schedule::Load::Safe;
ok(1);

my $safe = Schedule::Load::Safe->new();
ok($safe);

print "Is our function correct?\n";
my $func = sub { return ($_[0]->{two}); };
ok($func->($subself) == 2);

print "Refs evaluate correctly?\n";
ok($safe->eval_cb(sub { return ($_[0]->{two}); }, $subself) == 2);

print "Strings evaluate correctly?\n";
ok($safe->eval_cb('sub { return ($_[0]->{two}); }', $subself) == 2);

# Second time cached strings evaluate correctly
ok($safe->eval_cb('sub { return ($_[0]->{two}); }', $subself) == 2);

print "Error case\n";
ok(!defined $safe->eval_cb('system("crash_and_die")', $subself));
$@ = undef;

print "Uncached performance\n";
profile_start();
for (my $i=0; $i<2000; $i++) {
    $safe->eval_cb("sub { return $i; }", $subself);
}
profile_end("2000 uncached evals");
ok(1);

print "Cached performance\n";
profile_start();
for (my $i=0; $i<2000; $i++) {
    $safe->eval_cb("sub { return 22; }", $subself);
}
profile_end("2000 cached evals");
ok(1);

# Did caching work, but not overflow memory?
ok(keys %{$safe->{_cache}} > 100 && keys %{$safe->{_cache}} < 1001);

######################################################################

our $_Last_Time = 0;
our $_Last_Time_Usec = 0;
sub profile_start {
    my ($time, $time_usec) = gettimeofday();
    $_Last_Time = $time;
    $_Last_Time_Usec = $time_usec;
}
sub profile_end {
    my $category = shift || 'undef';
    my ($time, $time_usec) = gettimeofday();
    my $dtime_usec = $time_usec - $_Last_Time_Usec;
    my $dtime = $time - $_Last_Time + $dtime_usec*1.0e-6;
    printf(" Profile time %08.6f for $category\n", $dtime, $category);
    return $dtime;
}


