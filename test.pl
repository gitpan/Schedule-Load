#$Id: test.pl,v 1.13 2000/11/03 21:24:58 wsnyder Exp $
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

use Sys::Hostname;
use IO::Socket;

$SIG{INT} = \&cleanup_and_exit;
#$Debug = 1;

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..12\n";
	print "****NOTE****: You need 'slchoosed &' and 'slreportd &' running for this test!\n";
	print "** I'm starting them under a subprocess\n";
    }
END {print "not ok 1\n" unless $loaded;}

BEGIN {
    (eval 'use Proc::ProcessTable;1;') or die "not ok 1: %Error: You must install Proc::ProcessTable!\n";
    (eval 'use Unix::Processors;1;') or die "not ok 1: %Error: You must install Unix::Processors!\n";
}

use Schedule::Load::Schedule;
$loaded = 1;
print "ok 1\n";

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
    start_server ("./slchoosed");
    sleep 1;
    start_server ("./slreportd class_verilog=1 reservable=1 --stored_filename=./test_store/".hostname());
    check_server_up(8);  # 2*(4 children: perl, sh, daemon master, daemon slave)
    sleep 5;
}

############

# 2: Constructor
print (($scheduler = new Schedule::Load::Schedule
	( %Invoke_Params,
	  print_down=>sub { die "%Error: Can't locate sch server\n"
				. "\tRun 'slchoosed &' before this test\n";
			}
	  )) ? "ok 2\n" : "not ok 2\n");

# 3: Machines
print (($scheduler->print_hosts
	) ? "ok 3\n" : "not ok 3\n");

# 4: Classes
print (($scheduler->print_classes
	) ? "ok 4\n" : "not ok 4\n");

# 5: Top processes
print (($scheduler->print_top
	) ? "ok 5\n" : "not ok 5\n");

# 6: Cpus
my $cpus = $scheduler->cpus;
print "Total cpus in network: $cpus\n";
print (($cpus>0) ? "ok 6\n\n" : "not ok 6\n\n");

# 7: Choose host, get this one
my @classes = $scheduler->classes();
#testclass (@classes);
testclass (['verilog']);
print ((1) ? "ok 7\n\n" : "not ok 7\n\n");

# 8: Check holds
print (check_load() ? "ok 8\n\n" : "not ok 8\n\n");

# 9: Release holds
foreach (keys %Hold_Keys) {
    $scheduler->hold_release (hold_key=>$_);
    my $host = $Hold_Keys{$_};
    $Host_Load{$host}--;
    delete $Hold_Keys{$_};
}
print "ok 9\n\n";

# 10: Fixed loading
$scheduler->fixed_load (load=>10, pid=>$$);
$Host_Load{hostname()} += 10;
print "ok 10\n\n";

# 11: Retrieve loading...
check_load() ? "ok 11\n\n" : "not ok 11\n\n";

# Establish reservation
$scheduler->reserve();

# Release reservation
$scheduler->release();

# 12: Commentary
$scheduler->cmnd_comment (pid=>$$, comment=>"test.pl_comment_check");
$scheduler->fetch;
print $scheduler->print_top() if $Debug;
# No way to insure our job is on top, so can't test it
#print (($scheduler->print_top() =~ /_comment_check/)
print ((1) ? "ok 12\n\n" : "not ok 12\n\n");

## 99: Destructor
undef $scheduler;
print "\nok 99\n";

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
    while ($try--) {
	my @children = Schedule::Load::_subprocesses();
	print "@children\n" if $Debug;
	return if ($#children == $children-1);
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
	foreach (Schedule::Load::_subprocesses($pid)) {
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
