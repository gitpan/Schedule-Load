#$Id: test.pl,v 1.18 2001/12/06 18:24:47 wsnyder Exp $
# DESCRIPTION: Perl ExtUtils: Type 'make test' to test this package
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

use Sys::Hostname;
use IO::Socket;
use Test;

BEGIN { plan tests => 3 }

$SIG{INT} = \&cleanup_and_exit;

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..12\n";
	print "****NOTE****: You need 'slchoosed &' and 'slreportd &' running for this test!\n";
	print "** I'm starting them under a subprocess\n";
    }
ok(1);

BEGIN {
    (eval 'use Proc::ProcessTable;1;') or die "not ok 1: %Error: You must install Proc::ProcessTable!\n";
    (eval 'use Unix::Processors;1;') or die "not ok 1: %Error: You must install Unix::Processors!\n";
}

use Schedule::Load::Schedule;
$loaded = 1;
ok(1);

if ($Schedule::Load::_Default_Params{port} =~ /^\d$/) {
    print "%Note: You do not have slchoosed in /etc/services, may want to add\nslchoosed\t1752/tcp\t\t\t# Schedule::Load\n\n";
}

######################### End of black magic.

%Host_Load = ();  # min loading on each host
%Hold_Keys = ();  # holding keys in use

$Port = socket_find_free (12123);
%Invoke_Params = ( dhost => hostname(),
		   port => $Port,	# Fake port number so can test new version while running old
		   );

############
# Setup

#$Schedule::Load::Debug = $Debug;
#$Schedule::Load::Hosts::Debug = $Debug;

`rm -rf test_store`; #Ok if error
mkdir ('test_store', 0777);

############
# Start servers

if (1) {
    start_server ("./slchoosed --nofork");
    sleep 1;
    start_server ("./slreportd class_verilog=1 reservable=1 --nofork --stored_filename=./test_store/".hostname());
    check_server_up(6);  # (6 children: perl, sh, choose sh, choose, report sh, report)
    sleep 5;
}

############

# 2: Constructor
my $scheduler = new Schedule::Load::Schedule
    ( %Invoke_Params,
      print_down=>sub { die "%Error: Can't locate sch server\n"
			    . "\tRun 'slchoosed &' before this test\n";
		    }
      );
ok ($scheduler);

print "print_hosts check\n";
ok ($scheduler->print_hosts);

print "print_classes check\n";
ok ($scheduler->print_classes);

# 5: Top processes
ok ($scheduler->print_top);

# 6: Cpus
print "cpus check\n";
my $cpus = $scheduler->cpus;
print "Total cpus in network: $cpus\n";
ok ($cpus>0);

# 7: Choose host, get this one
my @classes = $scheduler->classes();
#testclass (@classes);
testclass (['verilog']);
ok(1);

# 8: Check holds
print "loads check\n";
ok(check_load());

# 9: Release holds
foreach (keys %Hold_Keys) {
    $scheduler->hold_release (hold_key=>$_);
    my $host = $Hold_Keys{$_};
    $Host_Load{$host}--;
    delete $Hold_Keys{$_};
}
ok(1);

# 10: Fixed loading
$scheduler->fixed_load (load=>10, pid=>$$);
$Host_Load{hostname()} += 10;
ok(1);

# 11: Retrieve loading...
ok(check_load());

# Establish reservation
$scheduler->reserve();

# Release reservation
$scheduler->release();

# 12: Commentary
$scheduler->cmnd_comment (pid=>$$, comment=>"test.pl_comment_check");
$scheduler->fetch;
print $scheduler->print_top() if $Debug;
# No way to insure our job is on top, so can't test it
#ok($scheduler->print_top() =~ /_comment_check/);
ok(1);

## 99: Destructor
undef $scheduler;
ok(1);

print "\nYou would be well advised to look for and kill any\n";
print "slreportd jobs that are running on --port $Port\n";
print "This program's kill isn't always reliable\n";

######################################################################
######################################################################
# Test subroutines

sub check_load {

    $scheduler->fetch;	# Else cache will still have old loading
    foreach my $hostname (keys %Host_Load) {
	my $host = $scheduler->get_host ($hostname);
	if (!$host) {
	    warn "%Warning: Host $hostname not accessable\n";
	    return 0;
	}
	my $load = $host->adj_load;
	if ($load < $Host_Load{$hostname}) {
	    warn "%Warning: Adjusted load incorrect, $hostname load=$load, expected=$Host_Load{$hostname}\n";
	    print $scheduler->print_hosts;
	    return 0;
	}
    }
    return 1;
}

sub testclass {
    my $classlist = shift;

    print "="x70, "\n";
    print "Machines of class ", join(' ',@{$classlist}), ":\n";
    foreach my $host ($scheduler->hosts_of_class(classes => $classlist)) {
	printf "  %s", $host->hostname;
    }
    print "\n\n";
    
    for (my $i=0; $i<2; $i++) { #FIX 20

	if ($Debug) {
	    $scheduler->fetch;
	    print $scheduler->print_hosts;
	}

	my $key = "Perl_Test_".$$."_$i";
	$best = $scheduler->best(classes => $classlist,
				 hold_key => $key);
	if ($best) {
	    $Host_Load{$best} ++;
	    $Hold_Keys{$key} = $best;
	    $jobs = $scheduler->jobs(classes => $classlist);
	    print "Best is $best, suggest $jobs jobs\n";
	} else {
	    warn "%Warning: No machines found\n";
	}
    }
}

######################################################################
######################################################################
# Socket subroutines

sub socket_find_free {
    my $port = shift;	# Port # to start looking on

    for (; $port<(1<<15); $port++) {
	print "Looking for free port $port\n" if $Debug;
	my $fh;
	$fh = IO::Socket::INET->new( Proto     => "tcp",
				     PeerAddr  => hostname(),
				     PeerPort  => $port,
				     );
	if ($fh) { # Port exists, try again
	    $fh->close();
	    next;
	}
	$fh = IO::Socket::INET->new( Proto     => 'tcp',
				     LocalPort => $port,
				     Listen    => SOMAXCONN,
				     Reuse     => 0);
	if ($fh) {
	    $fh->close();
	    return $port;
	}
    }
    die "%Error: Can't find free socket port\n";
}

######################################################################
######################################################################
# Starting subprocesses and cleaning them up

sub check_server_up {
    my $children = shift;
    # Are the servers up?  Look for the specific number of children to be running
    my $try = 60;
    print "Checking for $children server children\n";
    while ($try--) {
	my @children = Schedule::Load::_subprocesses();
	print "@children\n" if $Debug||1;
	if ($#children == $children-1) {
	    print "  Found\n";
	    return;
	}
	sleep 1;
    }
    die "%Error: Children never started correctly,\nplease try running the daemons in the foreground\n";
}

{#static
my %pids;
END { cleanup_and_exit(); }
sub cleanup_and_exit {
    # END routine to kill children
    foreach my $pid (keys %pids) {
	next if !$pid;
	my @proc = Schedule::Load::_subprocesses($pid);
	foreach (@proc) {
	    kill 9, $_;  print "  Killing $_ (child of $pid)\n";
	}
	kill 9, $pid;  print "  Killing $pid (started it earlier)\n";
    }
    exit(0);
}

sub start_server {
    my $prog = shift;
    # start given server program in background

    $prog = "xterm -e $prog" if $Debug;

    my $cmd = "$prog --port $Invoke_Params{port} --dhost $Invoke_Params{dhost}";
    $cmd .= " --debug" if $Debug;
    $cmd .= " --nofork";  # Need children under this parent so can kill them
    $cmd .= " && perl -e '<STDIN>'";

    $pid = fork();
    if ($pid==0) {
	system ($cmd);
	exit($?);
    }
    print "Starting pid $pid, $cmd\n";
    $pids{$pid} = $pid;
}
}#static
