# Schedule::Load::Chooser.pm -- distributed lock handler
# See copyright, etc in below POD section.
######################################################################

package Schedule::Load::Chooser;
require 5.004;
require Exporter;
@ISA = qw(Exporter);

use POSIX;
use Socket;
use IO::Socket;
use IO::Poll;
use Tie::RefHash;
use Net::hostent;
use Sys::Hostname;
use Sys::Syslog;
use Time::HiRes qw (gettimeofday);
BEGIN { eval 'use Data::Dumper; $Data::Dumper::Indent=1; $Data::Dumper::Sortkeys=1;';}	#Ok if doesn't exist: debugging only
#use Devel::Leak; our $Leak;

use Schedule::Load qw (:_utils);
use Schedule::Load::Schedule;
use Schedule::Load::Hosts;
use IPC::PidStat;

use strict;
use vars qw($VERSION $Debug %Clients $Hosts $Client_Num $Poll
	    $Exister
	    @Messages
	    $Time $Time_Usec
	    $Server_Self %ChooInfo);
use vars qw(%Holds);  # $Holds{hold_key}[listofholds] = HOLD {hostname=>, scheduled=>1,}
use Carp;

use constant POLLIN_ETC => (POLLIN | POLLERR | POLLHUP | POLLNVAL);

######################################################################
#### Configuration Section

# Other configurable settings.
$Debug = $Schedule::Load::Debug;

$VERSION = '3.064';

use constant RECONNECT_TIMEOUT => 180;	  # If reconnect 5 times in 3m then somthing is wrong
use constant RECONNECT_NUMBER  => 5;
use constant LOG_MESSAGE_TIMEOUT => 20*60; # Secs to expire old messages
use constant LOG_MESSAGE_COUNT => 50; # Maximum messages to keep (so don't overflow memory)
use constant _BLOCKING_TEST => 0;  # Test the behavior of EWOULDBLOCK; very bad for performance

######################################################################
#### Globals

%Clients = ();
tie %Clients, 'Tie::RefHash';

stash_time();
%ChooInfo = (# Information to pass to "rschedule info"
	     slchoosed_hostname => hostname(),
	     slchoosed_connect_time => time(),
	     slchoosed_status => "Started",
	     slchoosed_version => $VERSION,
	     );

######################################################################
#### Creator

sub start {
    # Establish the server
    @_ >= 1 or croak 'usage: Schedule::Load::Chooser->start ({options})';
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = {
	%Schedule::Load::_Default_Params,
	#Documented
	dynamic_cache_timeout=>10,	# Secs to hold cache for, if not set differently by reporter
	dynamic_slow_timeout=>9,	# Secs to wait for response before considering host unresponsive and ignoring it
	ping_dead_timeout=>300,		# Secs lack of ping indicates dead (greater than reporter's alive_time)
	#Debug: dynamic_cache_timeout=>2, dynamic_slow_timeout=>5, ping_dead_timeout=>10,
	subchooser_restart_num=>12,	# For first 12 times,
	subchooser_first_time=>20,	# Sec between first 12 chooser_restart_if_reporters
	subchooser_repeat_time=>(5*60),	# Sec between other chooser_restart_if_reporters
	@_,};
    bless $self, $class;
    $Server_Self = $self;	# Only should be one... Need some options

    # Open the socket
    _timesyslog('info',"slchoosed up on ".hostname()." $self->{port}\n");
    my $server = IO::Socket::INET->new( Proto     => 'tcp',
					LocalPort => $self->{port},
					Listen    => SOMAXCONN,
					Reuse     => 1)
	or die "$0: Error, socket: $!";

    $Poll = IO::Poll->new;
    $Poll->mask($server => POLLIN_ETC);

    $Hosts = Schedule::Load::Schedule->new(_fetched=>-1,);  #Mark as always fetched

    $Exister = new IPC::PidStat();
    $Poll->mask($Exister->fh => POLLIN_ETC);

    # Update status
    $self->_chooser_set_status();

    $self->_probe_reset_check();

    while (1) {
	# Anything to read?
	my @r; my @w;
	my $npolled = $Poll->poll(3);  #3 secs maximum
	if ($npolled>=0) {
	    @r = $Poll->handles(POLLIN);
	    @w = $Poll->handles(POLLOUT);
	}
	#if ($Debug) { my @h=$Poll->handles; _timelog("Poll $npolled : list$#h r$#r w$#w $!\n"); }
	foreach my $fh (@r) {
	    stash_time();	# Cache the time
	    if ($fh == $server) {
		# Accept a new connection
		_timelog("Accept\n") if $Debug;
		my $clientfh = $server->accept();
		next if !$clientfh;
		$Poll->mask($clientfh => POLLIN_ETC);
		my $flags = fcntl($clientfh, F_GETFL, 0) or die "%Error: Can't get flags";
		fcntl($clientfh, F_SETFL, $flags | O_NONBLOCK) or die "%Error: Can't nonblock";
		# new Client
		my $client = {socket=>$clientfh,
			      delayed=>0,
			      ping_time => $Time,
			      last_reqdyn_time => undef,
			      inbuffer => '',
			      outbuffer => '',
			  };
		$Clients{$clientfh} = $client;
	    }
	    elsif ($fh == $Exister->fh) {
		_exist_traffic();
	    }
	    else {
		# Input traffic on other client
		_client_service($Clients{$fh});
	    }
	}
	foreach my $fh (@w) {
	    _timelog("poll now allows write\n") if _BLOCKING_TEST;
	    _client_send($Clients{$fh},'');
	}
	# Action or timer expired, only do this if time passed
	if (time() != $Time) {
	    stash_time();	# Cache the time
	    _hold_timecheck();
	    _client_ping_timecheck();
	    $self->_probe_reset_check();
	}
    }
}

sub stash_time {
    # Cache the time, store in a variable to avoid a OS call inside a loop
    ($Time, $Time_Usec) = gettimeofday();
}

######################################################################
#### Host probing

sub _probe_init {
    my $self = shift;
    # Create list of all hosts "below" this one on the list of all slchoosed servers

    my @hostlist = ($self->{dhost});
    @hostlist = @{$self->{dhost}} if (ref($self->{dhost}) eq "ARRAY");
    my $host_this = gethost(hostname());

    my $hit = 0;
    my @subhosts;
    foreach my $host (@hostlist) {
	my $hostx = $host;
	if (my $h = gethost($host)) {
	    _timelog("_probe_init (host $host => ",$host_this->name,")\n") if $Debug;
	    if (lc($h->name) eq lc($host_this->name)) {
		$hit = 1;
	    } elsif ($hit) {
		push @subhosts, $host;
	    }
	}
    }
    _timelog("_probe_init subhosts= (@subhosts)\n") if $Debug;
    $self->{_subhosts} = \@subhosts;
}

sub _probe_reset_check {
    my $self = shift;
    # Send a _probe_reset every so often
    if (($self->{_probe_reset_next_time}||0) < $Time) {
	my $delay = ((($self->{_probe_reset_times}||0) < $self->{subchooser_restart_num})
		     ? $self->{subchooser_first_time} : $self->{subchooser_repeat_time});
	$self->{_probe_reset_times}++;
	$self->{_probe_reset_next_time} = $Time + $delay;
	$self->_probe_reset();
    }
}

sub _probe_reset {
    my $self = shift;
    # Tell all subserviant hosts that a new master is on the scene.
    # Start at top and work down, want to ignore ourself and everyone
    # before ourself.
    $self->_probe_init();
    foreach my $host (@{$self->{_subhosts}}) {
	_timelog("_probe_reset $host $self->{port} trying...\n") if $Debug;
	my $fhreset = Schedule::Load::Socket->new (
					     PeerAddr  => $host,
					     PeerPort  => $self->{port},
					     Timeout   => $self->{timeout},
					     );
	if ($fhreset) {
	    _timelog("_probe_reset $host restarting\n") if $Debug;
	    print $fhreset _pfreeze("chooser_restart_if_reporters", {}, $Debug);
	    $fhreset->close();
	    _timelog("_probe_reset $host DONE\n") if $Debug;
	}
    }
}

sub _chooser_set_status {
    my $self = shift;
    $self->_probe_init();
    my $subhosts="";
    foreach my $host (@{$Server_Self->{_subhosts}}) {
	$subhosts .= ($subhosts ? ":" : "; primary to ");
	$subhosts .= $host;
    }
    $ChooInfo{slchoosed_connect_time} = time();
    $ChooInfo{slchoosed_status} = "Connected".$subhosts;
}

######################################################################
######################################################################
#### Client servicing

sub _client_close {
    # Close this client
    my $client = shift || return;

    my $fh = $client->{socket};
    _timelog("Closing client $fh\n") if $Debug;

    if ($client->{host}) {
	my $host = $client->{host};
	my $hostname = $host->hostname || "";	# Will be deleted, so get before delete
	_timelog(" Closing host ",$host->hostname,"\n") if $Debug;
	_timesyslog("info","slreportd $hostname disconnected\n");
	delete $Hosts->{hosts}{$hostname};
	delete $host->{const};	# Delete before user_wait, so user doesn't see them
	delete $host->{stored};
	delete $host->{dynamic};
	_user_wait_finish ($host);
	delete $host->{client};
    }

    $Poll->remove($fh);
    eval {
	$fh->close();
    };

    delete $client->{host};   # Prevent circular ref leak
    delete $Clients{$fh};

    if (0) { #Leak checking
	$fh = undef;
	$client = undef;
	#Devel::Leak::CheckSV($Leak) if $Leak;
	#Devel::Leak::NoteSV($Leak);
    }
}

sub _client_close_all {
    # For debugging; close all clients
    my @clients = (values %Clients);
    foreach (@clients) { _client_close ($_); }
}

sub _client_done {
    # Done with this client
    my $client = shift || return;
    _client_send($client, "DONE\n");
}

sub _client_service {
    # Loop getting commands from a specific client
    my $client = shift || return;

    my $fh = $client->{socket};
    my $data = '';
    my $rv;
    while (1) {
	$! = undef;
	$rv = $fh->sysread($data, POSIX::BUFSIZ);
	last if $! != POSIX::EINTR && $! != POSIX::EAGAIN;
    }
    if (!defined $rv || (length $data == 0))
    {
	# End of the file
	_client_close ($client);
	return;
    }

    $client->{inbuffer} .= $data;
    $client->{ping_time} = $Time;

    while ($client->{inbuffer} =~ s/^([^\n]*)\n//) {
	next if $client->{_broken};
	my $line = $1;
	#_timelog("CHOOSER GOT: $line\n") if $Debug;
	_timelog($client->{host} ? "$client->{host}{hostname}  ":"client-$fh  ") if $Debug;
	my ($cmd, $params) = _pthaw($line, $Debug);

	if ($cmd eq "report_ping") {
	    # NOP, timestamp recorded above
	} elsif ($cmd eq "report_const") {
	    # Older reporters don't have the _update flag, so support them too
	    _host_start ($client, $params) if !$params->{_update};
	    _host_dynamic ($client, "const", $params) if !$client->{_broken};
	    _host_const_chooseinfo($client->{host});
	} elsif ($cmd eq "report_stored") {
	    _host_dynamic ($client, "stored", $params);
	} elsif ($cmd eq "report_dynamic") {
	    _host_dynamic ($client, "dynamic", $params);
	    $client->{host}{_dyn_update} = $Time;
	    $client->{host}{_reqdyn_pending} = 0;
	    $client->{host}{const}{slreportd_unresponsive} = undef;
	    if ($client->{last_reqdyn_time}) {
		my $sec  = $Time - $client->{last_reqdyn_time}[0];
		my $usec =  $Time_Usec - $client->{last_reqdyn_time}[1];
		$client->{host}{const}{slreportd_delay} = $sec + $usec * 1.0e-6;
	    }
	    _user_wait_finish ($client->{host});
	}
	# User commands
	elsif ($cmd eq "get_const_load_proc"
	       || $cmd eq "get_const_load_proc_chooinfo"
	       ) {
	    _user_get ($client, "report_get_dynamic\n", $cmd);
	} elsif ($cmd eq "schedule") {
	    _user_schedule ($client, $params);
	} elsif ($cmd =~ /^report_fwd_/) {	# All can just be forwarded
	    _user_to_reporter ($client, [$params->{host}], $line."\n");
	    _client_done ($client);
	} elsif ($cmd eq "hold_release") {
	    _hold_delete ($Holds{$params->{hold_key}});
	    _client_done ($client);
	}
	# User reset
	elsif ($cmd eq "report_restart") {
	    _user_to_reporter ($client, '-all', "report_restart\n");
	    _client_done ($client);
	} elsif ($cmd eq "chooser_restart") {
	    # Overall fork loop will deal with it.
	    warn "-Info: chooser_restart\n" if $Debug;
	    exit(0);
	} elsif ($cmd eq "chooser_restart_if_reporters") {
	    # Used by master chooser to restart subservient chooser
	    foreach my $host ($Hosts->hosts_unsorted, (values %Clients)) {
		next if $host eq $client;   # Skip the requestor itself
		# Overall fork loop will deal with it.
		warn "-Info: chooser_restart_if_reporters\n" if $Debug;
		exit(0);
	    } # else no hosts
	    _client_done ($client);
	} elsif ($cmd eq "chooser_close_all") {
	    _client_close_all ($client);
	} else {
	    my $peer = _client_peeraddr($client)||'';
	    print "%Warning: $peer: REQ UNKNOWN '$line\n" if $Debug;
	}
    }
}

sub _client_send {
    my $client = shift || return;
    my $out = join "", @_;
    # Send any arguments to the client
    # Returns 0 if failed, else 1

    $SIG{PIPE} = 'IGNORE';

    # Append to outbuffer
    $client->{outbuffer} .= $out;
    my $fh = $client->{socket};

    while ($client->{outbuffer} ne "") {
	my $ok = 1;

	if (!$fh || !$fh->connected()) {
	    _client_close ($client);
	    return 0;
	}

	_timelog("_client_send_BLOCK ",length($client->{outbuffer}),"\n") if _BLOCKING_TEST;
	my $rv = eval { return $fh->syswrite($client->{outbuffer}, _BLOCKING_TEST?10:undef); };
	# Node ->connected call does a system getpeeraddr() call
	if (!$fh || !$fh->connected() || ($! && $! != POSIX::EWOULDBLOCK)) {
	    _client_close ($client);
	    return 0;
	}
	# Truncate what did get out
	$client->{outbuffer} = substr ($client->{outbuffer}, $rv) if $rv;

	if (_BLOCKING_TEST) {
	    _timelog("testing blocking; fake return here\n");
	    $rv = undef;
	}
	if (!defined $rv) {  # Couldn't write: very rare
	    _timelog("Client syswrite would block, sending later\n") if $Debug;
	    $Poll->mask($fh => (POLLIN_ETC | POLLOUT));
	    $client->{_poll_out_mask} = 1;
	    return 1;  # Ok, do rest later.
	}
    }

    if ($client->{_poll_out_mask}) {  # All sent; stop polling for output ready
	$Poll->mask($fh => POLLIN_ETC);
	$client->{_poll_out_mask} = 0;
    }
    return 1; # Ok
}

sub _client_peeraddr {
    my $client = shift || return undef;
    # This may be slow - it may call the kernel, so only use it in debug code!
    my $fh = $client->{socket} || return undef;
    my $peer = getpeername($fh) || return undef;
    my ($port,$ip) = sockaddr_in($peer);
    return if !$port;
    return inet_ntoa($ip).":$port";
}

sub _client_ping_timecheck {
    # See if any clients haven't pinged
    foreach my $client (values %Clients) {
	#print "Ping Check $client->{ping_time} Now $Time  Dead $Server_Self->{ping_dead_timeout}\n" if $Debug;
	if (my $host = $client->{host}) {
	    if (($Time - $client->{ping_time}) > $Server_Self->{ping_dead_timeout}) {
		my $hostname = $host->{hostname} || "UNK";
		_timesyslog("notice", "slreportd $hostname not responsive, bye\n");
		_client_close ($client);
	    } elsif ($host->{_reqdyn_pending}
		     && (($Time - $host->{_reqdyn_pending}) > $Server_Self->{dynamic_slow_timeout})) {
		my $hostname = $host->{hostname} || "UNK";
		if (!$host->{const}{slreportd_unresponsive}) {
		    _timesyslog("info", "slreportd $hostname seems slow to respond\n");
		}
		$host->{const}{slreportd_delay} = $Time - $host->{_reqdyn_pending};
		$host->{const}{slreportd_unresponsive} = $Time;
		_user_wait_finish ($host);
	    }
	}
    }
}

######################################################################
######################################################################
######################################################################
######################################################################
#### Services for slreportd calls

sub _host_start {
    my $client = shift || return;
    my $params = shift;
    # const command: establish a new host, load constants
    my $hostname = $params->{hostname};

    # Only sent at first establishment, so we blow away old info
    _timelog("Connecting $hostname\n") if $Debug;
    my $host = {  client => $client,
		  hostname => $hostname,
		  waiters => {},
		  const => $params,
	      };
    bless $host, "Schedule::Load::Hosts::Host";

    _host_const_chooseinfo($host);

    # Remove any earlier connection
    my $oldhost = $Hosts->{hosts}{$hostname};
    if (defined $oldhost->{client}) {
	_timelog("$hostname was connected before, reconnected\n") if $Debug;
	if ($host->{const}{slreportd_connect_time}
	    < ($oldhost->{const}{slreportd_connect_time} + RECONNECT_TIMEOUT)) {
	    $host->{const}{slreportd_status} = "Reconnected";
	    $host->{const}{slreportd_reconnects} = ($oldhost->{const}{slreportd_reconnects}||0)+1;
	    if ($host->{const}{slreportd_reconnects} > RECONNECT_NUMBER) {
		# We have two reporters fighting.  Tell what's up and ignore all data.
		my $cmt = ("%Error: Conflicting slreportd deamons on ".$oldhost->slreportd_hostname
			   ." and ".$host->slreportd_hostname);
		_timesyslog("notice",$cmt."\n");
		$oldhost->{const}{slreportd_status} = $cmt;
		$oldhost->{stored}{reserved} = $cmt;
		$host->{client}{_broken} = 1;
		$client->{_broken} = 1;
		return;
	    }
	    _client_close($oldhost->{client});
	}
    } else {
	_timesyslog("info","slreportd $hostname joined\n");
    }

    tie %{$host->{waiters}}, 'Tie::RefHash';
    $Hosts->{hosts}{$hostname} = $host;
    $client->{host} = $host;
    #_timelog("const: ", Data::Dumper::Dumper($host)) if $Debug;
}


sub _host_const_chooseinfo {
    my $host = shift;
    $host->{const}{slreportd_connect_time} ||= time();
    $host->{const}{slreportd_status} ||= "Connected";
    $host->{const}{slreportd_delay} ||= undef;
}

sub _host_dynamic {
    my $client = shift || return;
    my $field = shift;
    my $params = shift;
    # load/proc command:
    $client->{host}{$field} = $params;
}

######################################################################
######################################################################
######################################################################
######################################################################
#### Services for user calls

sub _user_to_reporter {
    my $userclient = shift;
    my $hostnames = shift;	# array ref, or '-all'
    my $cmd = shift;

    if ($hostnames eq '-all') {
	my @hostnames = ();
	foreach my $host ($Hosts->hosts_unsorted) {
	    # We'll notifiy even "unresponsive" hosts
	    push @hostnames, $host->hostname;
	}
	$hostnames = \@hostnames;
    }

    foreach my $hostname (@{$hostnames}) {
	my $host = $Hosts->{hosts}{$hostname};
	next if !$host;
	$host->{_dyn_update} = 0;	# Kill cache, will need refresh
	$host->{_reqdyn_pending} = 0;	# Kill cache, will need refresh
	_timelog("_user_to_reporter ->$hostname $cmd") if $Debug;
	_client_send ($host->{client}, $cmd);
    }
}

sub _user_get {
    my $userclient = shift;
    my $cmd = shift;
    my $flags = shift;

    my $cmd_start_time = [$Time, $Time_Usec];
    _user_wait_action ($userclient,
		       \&_user_send_done_cb, [$userclient, $flags, $cmd_start_time]);
    _user_all_hosts_cmd ($userclient, $cmd, undef);
    _user_wait_check($userclient);
}

sub _user_send_done_cb {
    my $userclient = shift;
    my $flags = shift;
    my $cmd_start_time = shift;
    _user_send ($userclient, $flags, $cmd_start_time);
    _client_done ($userclient);
}

sub _user_all_hosts_cmd {
    my $userclient = shift;
    my $cmd = shift;
    my $schparams = shift;	# Schedule request to select hosts, or undef for all hosts

  host:
    foreach my $host ($Hosts->hosts_unsorted) {
	# We include unresponsive hosts
	my $dynto = ($host->get_undef('dynamic_cache_timeout') || $Server_Self->{dynamic_cache_timeout});

	# For easier debug, be sure to have a _timelog under each of these branches
	if ($host->{_dyn_update}
	    && $host->{_dyn_update} > ($Time - $dynto)) {
	    # This is the fastest test and exit, so leave as first if(...) term
	    _timelog("  GETskip _cached ->", $host->hostname, " $cmd") if $Debug;
	    next host;
	}

	# Cache isn't fresh
	# Test the match list
	if ($schparams && $schparams->{resources}) {
	    my $match;
	  resreq:
	    foreach my $resreq (@{$schparams->{resources}}) {
		if ($host->host_match_chooser($resreq,undef)) {
		    $match = 1;
		    last resreq;
		}
	    }
	    if (!$match) {
		# classes doesn't match this host.  
		_timelog("  GETskip _no_host_match ->", $host->hostname, " $cmd") if $Debug;
		next host;
	    }
	}

	if ($host->{const}{slreportd_unresponsive}) {
	    # Reporter hasn't given us a result in a while, so don't bother to ask it for more work
	    # This also prevents a "ping_slow_timeout" length pause for *every* requestor.
	    # We assume it will evenutally give a reply, which will clear unresponsive.
	    # If not, it'll eventually hit the ping_dead_timeout
	    _timelog("  GETskip _unresponsive ->", $host->hostname, " $cmd") if $Debug;
	    # Update timestamp so "rschedule status" sees it increment
	    $host->{const}{slreportd_delay} = $Time - $host->{_reqdyn_pending};
	} else {
	    # Cache is out of date.
	    if ($host->{_reqdyn_pending}) {  # Otherwise only issue one request, it'll satisfy everyone.
		# Already issued response, but haven't gotten it, wait for existing request
		_timelog("  GETskip reqdyn_pending ->", $host->hostname, " $cmd") if $Debug;
		_user_wait_mark ($host, $userclient);
	    } else {
		_timelog("  GET ->", $host->hostname, " $cmd") if $Debug;
		if ($cmd =~ /report_get_dynamic/) {
		    $host->{client}{last_reqdyn_time} = [$Time, $Time_Usec]; # For DELAY column
		}
		if (_client_send ($host->{client}, $cmd)) {
		    # Mark that we need activity from each of these before being done
		    $host->{_reqdyn_pending} = $Time;
		    _user_wait_mark ($host, $userclient);
		} # Else host down; ignore it
	    }
	}
    }
}

sub _user_send {
    my $client = shift;
    my $types = shift;
    my $cmd_start_time = shift;
    # Send requested types of information back to the user
    _timelog("_user_send $client $types\n") if $Debug;
    _holds_adjust();
    _user_send_type ($client, "const") if ($types =~ /const/);
    _user_send_type ($client, "stored") if ($types =~ /load/);
    _user_send_type ($client, "dynamic") if ($types =~ /load/ || $types =~ /proc/);
    if ($types =~ /chooinfo/) {
	_update_chooinfo (($Time - $cmd_start_time->[0]) + ($Time_Usec - $cmd_start_time->[1]) * 1.0e-6);
	_client_send    ($client, _pfreeze ("chooinfo", \%ChooInfo, 0));
    }
}

sub _user_send_type {
    my $client = shift;
    my $type = shift;
    # Send specific data type to user
    my @frozen;
    foreach my $host ($Hosts->hosts_sorted) {
	# We include unresponsive hosts
	if (defined $host->{$type}
	    # If the host is really slow it may have just connected but not yet sent all
	    # of the dynamic information.  If so, ignore it.
	    && $host->{hostname} && $host->{_dyn_update}) {
	    #_timelog("Host $host name $host->{hostname}\n") if $Debug;
	    my %params = (table => $host->{$type},
			  type => $type,
			  hostname => $host->{hostname},
			  );
	    # Rather than sending lots of little packets, join them all up to send
	    # in one large packet.
	    push @frozen, _pfreeze ("host", \%params, 0&&$Debug);
	}
    }
    if (0==_client_send ($client, join('',@frozen))) {
	# Send failed
    }
}

######################################################################

sub _user_wait_action {
    my $userclient = shift;
    my $callback = shift;
    my $argsref = shift;
    $userclient->{wait_count} = 0;
    $userclient->{wait_action} = $callback;
    $userclient->{wait_action_argsref} = $argsref;
}

sub _user_wait_mark {
    my $host = shift;
    my $userclient = shift;
    # Mark this user as needing new info from host before returning status

    $host->{waiters}{$userclient} = 1;
    $userclient->{wait_count} ++;
}

sub _user_wait_finish {
    my $host = shift;
    # Host finished, dec count see if done with everything client needed

    foreach my $userclient (keys %{$host->{waiters}}) {
	_timelog("Dewait $host $userclient\n") if $Debug;
	delete $host->{waiters}{$userclient};
	$userclient->{wait_count} --;
	_user_wait_check($userclient);
    }
}

sub _user_wait_check {
    my $userclient = shift;
    if ($userclient->{wait_count} == 0) {
	_timelog("Dewait *DONE*\n") if $Debug;
	&{$userclient->{wait_action}} (@{$userclient->{wait_action_argsref}});
	$userclient->{wait_action} = undef;  # Done, prevent leaks
	$userclient->{wait_action_argsref} = undef;  # Done, prevent leaks
    }
}

######################################################################
######################################################################
######################################################################
######################################################################
#### Scheduling

sub _user_schedule_sendback {
    my $userclient = shift;
    my $schparams = shift;
    # Schedule and return results to the user

    my $schresult = _schedule ($schparams);
    _client_send ($userclient, _pfreeze ("schrtn", $schresult, $Debug));
    _client_done ($userclient);
}

sub _user_schedule {
    my $userclient = shift;
    my $schparams = shift;

    _user_wait_action ($userclient,
		       \&_user_schedule_sendback, [$userclient, $schparams]);
    _user_all_hosts_cmd ($userclient, "report_get_dynamic\n", $schparams);
    _user_wait_check($userclient);
}

sub _schedule_one_resource {
    my $schparams = shift;
    my $resreq = shift;		# ResourceReq reference
    my $resscratch = shift;	# Passed to user's callback; not safe for internals; they may modify it!

    #Factors:
    #  hosts_match:  reserved, match_cb, classes
    #	   -> Things that absolutely must be correct to schedule here
    #  rating:	     rating_cb:  load_limit, cpus, clock, adj_load, tot_pctcpu, rating_adder, rating_mult
    #	   -> How to prioritize, if 0 it's overbooked
    #  loads_avail:  holds, fixed_load
    #	   -> How many more jobs host can take before we should turn off new jobs

    # Note we need to subtract resources which aren't scheduled yet, but have higher
    # priorities than this request.  This allows for a pool request of 10 machines
    # to eventually start without being starved by little 1 machine requests that keep
    # getting issued.

    my $bestref = undef;
    my $bestrating = undef;
    my $favorref = undef;
    my $favorhost = 0; $favorhost = $Hosts->get_host($resreq->{favor_host}) || 0 if ($resreq->{favor_host});
    my $freecpus = 0;
    my $totcpus = 0;
    # hosts_match can be slow, plus it constructs a list.  It's faster to loop here.
    foreach my $host ($Hosts->hosts_sorted) {
	next if $host->{const}{slreportd_unresponsive};
	# host_match takes: classes, match_cb, allow_reserved
	# we can remove $resscratch from here when code migrates to use rating_cb instead
	next if !$host->host_match_chooser($resreq,$resscratch);
	# Process the host
	$totcpus += $host->cpus;
	my $rating = $host->rating_chooser ($resreq->{rating_cb},$resscratch);
	_timelog("\tTest host ", $host->hostname," rate ",$rating,", cpus ",$host->cpus,", free ",$host->free_cpus,"\n") if $Debug;
	#_timelog("\t     adj_load ",$host->adj_load,", load_limit ",$host->load_limit,"\n") if $Debug;
	#_timelog(Data::Dumper->Dump([$host], ['host']),"\n") if $Debug;
	if ($rating > 0) {
	    my $machfreecpus = $host->free_cpus;
	    $freecpus += $machfreecpus;
	    if (!$schparams->{allow_none} || $machfreecpus) {
		# Else, w/allow_none even if this host has cpu time
		# left and a better rating, it might not have free job slots
		if ($host == $favorhost && $machfreecpus) {
		    # Found the favored host has resources, force it to win
		    $favorref = $host;
		    $bestref = undef; # For next if statement to catch
		}
		if (!defined $bestref
		    || (($rating < $bestrating) && !$favorref)) {
		    $bestref = $host;
		    $bestrating = $rating;
		}
	    }
	}
    }

    my $jobs = $freecpus;
    if ($resreq->{max_jobs}<=0) {  # Fraction that's percent of clump if negative
	$jobs = _min($jobs, int($totcpus * (-$resreq->{max_jobs})) - ($resreq->{jobs_running}||0));
    } else {
	$jobs = _min($jobs, $resreq->{max_jobs} - ($resreq->{jobs_running}||0));
    }
    my $keep_idle = $resreq->{keep_idle_cpus} || 0;
    if (($resreq->{keep_idle_cpus}||0) < 0) {  # Fraction that's percent of clump if negative
	$keep_idle = _max($keep_idle, int($totcpus * (-$resreq->{keep_idle_cpus})));
    }
    if ($schparams->{allow_none} && ($jobs<1 || $freecpus < $keep_idle)) {
	$bestref = undef;
    }
    $jobs = _max($jobs, 1);
    _timelog("    _Schedule_one Best ".($bestref?1:'none')
	     ." Jobs $jobs Totcpu $totcpus  Free $freecpus  Running ".($resreq->{jobs_running}||0)
	     ." Max $resreq->{max_jobs} KI $keep_idle\n") if $Debug;

    return ($bestref,$jobs);
}

sub _schedule {
    # Choose the best host and total resources available for scheduling
    my $schparams = shift;  #allow_none=>$, hold=>ref, requests=>[ref,ref...]
    _timelog("_schedule $schparams->{hold}{hold_key}\n") if $Debug;

    # Clear holds for this request, the user may have scheduled (and failed) earlier.
    my $schhold = $schparams->{hold};
    if (my $oldhold = $Holds{$schhold->hold_key}) {
	# Keep a old req_time, as a new identical request doesn't deserve to move to the end of the queue
	# This also prevents livelock problems where a scheduled hold was issued to the oldest request,
	# then that request returns and is no longer the oldest.
	$schhold->{req_time} = _min($schhold->{req_time}, $oldhold->{req_time});
	_hold_delete($oldhold);
    }
    _holds_clear_unallocated();
    _holds_adjust();

    _hold_add_schreq($schparams);
    $schparams->{hold} = undef;  # Now have schparams under hold, don't need circular reference

    # Loop through all requests and issue hold keys to those we can
    _timelog("_schedule_loop $schhold->{hold_key}\n") if $Debug;
    my $resdone = 1;
    my @reshostnames = ();
    my $resjobs;
    foreach my $hold (sort {$a->compare_pri_time($b)} (values %Holds)) {
	my $schreq = $hold->{schreq};
	next if !$schreq;
	# Careful, we generally want $schreq rather than $schparams in this loop...
	_timelog("  SCHREQ for $hold->{hold_key}\n") if $Debug;
	my %resscratch = ( partial_hosts=>[] );   # Passed to the user's callback
	foreach my $resref (@{$schreq->{resources}}) {
	    _timelog("    Ressch for $hold->{hold_key}\n") if $Debug;
	    my ($bestref,$jobs) = _schedule_one_resource($schreq,$resref,\%resscratch);
	    my $okref = $bestref;
	    if ($bestref) {
		# Found at least one CPU slot for this job
		_timelog("      Resdn   $jobs on ",$bestref->hostname," for $hold->{hold_key}\n") if $Debug;
		# We may have only gotten a single free CPU out of many wanted.
		# If this requires much tweaking, we'll make it a callback insted.
		if (my $limit = $bestref->get_undef('load_limit')) {
		    my $wantload = _hold_load_host_adjusted($hold,$bestref);
		    if (($limit - $bestref->adj_load) < $wantload) {
			_timelog("        **Not all CPUs ready on ",$bestref->hostname
				 ," (($limit-",$bestref->adj_load,")<$wantload),"
				 ," for $hold->{hold_key}\n") if $Debug;
			$okref = undef;
		    }
		}
		# Hold this resource so next schedule loop doesn't hit it
		_hold_add_host($hold, $bestref);
		$bestref = undef;  # Don't use bestref below, use okref
	    }
	    if ($okref) {
		# Found all the needed loads to complete this resource request
		push @{$resscratch{partial_hosts}}, $okref;  # For the user's rating_cb
	    }
	    if ($hold == $schhold) {   # We're scheduling the one the user asked for
		$resjobs = $jobs;
		if ($okref) {
		    push @reshostnames, $okref->hostname;
		} else {
		    # None found, we didn't schedule all resources it wanted
		    # Note there may be other resources it wants, so continue the loop...
		    $resdone = 0;
		}
	    }
	}
    }

    # If we scheduled ok, move the hold to a assigment, so next schedule doesn't kill it
    if ($resdone) {
	$schhold->{allocated} = 1;   # _holds_clear_unallocated checks this
	$schhold->{schreq} = undef;  # So we don't schedule it again
	# We don't need to do another hold_new, since we've changed the reference each host points to.
    }

    _timelog("DONE_HOLDS:  ",Data::Dumper::Dumper (\%Holds)) if $Debug;

    # Return the list of hosts we scheduled
    if ($resdone) {
	return {jobs => $resjobs,
		best => \@reshostnames,
		hold => $schhold,
	    };
    } else {
	return {jobs => $resjobs,
		best => undef,
		hold => undef,
	    };
    }
}

######################################################################
######################################################################
#### Holds

sub _hold_add_schreq {
    my $schreq = shift;
    # Add this request to the ordered list of requests
    $Holds{$schreq->{hold}->hold_key} = $schreq->{hold};
    my $hold = $Holds{$schreq->{hold}->hold_key};
    $hold->{schreq} = $schreq;
    $hold->{schreq}{hold} = undef;  # Now have schreq under hold, don't need circular reference
}

sub _hold_add_host {
    my $hold = shift;
    my $host = shift;
    # Hostnames must be a list, not a hash as we can have multiple holds
    # w/same request applying to the same host.
    $hold->{hostnames} ||= [];
    push @{$hold->{hostnames}}, $host->hostname;
    # Not: _holds_adjust, save unnecessary looping and just add the load directly.
    $host->{dynamic}{adj_load} += _hold_load_host_adjusted($hold,$host);
}

sub _hold_load_host_adjusted {
    my $hold = shift;
    my $host = shift;
    return (($hold->{hold_load}>=0) ? $hold->{hold_load} : $host->cpus);
}

sub _hold_delete {
    my $hold = shift;
    # Remove a load hold under speced key
    return if !defined $hold;
    _timelog("_hold_delete($hold->{hold_key})\n") if $Debug;
    delete $Holds{$hold->{hold_key}}{schreq};  # So don't loose memory from circular reference
    delete $Holds{$hold->{hold_key}};
}

sub _holds_clear_unallocated {
    # We're going to start a schedule run, delete any holds not on resources
    # that have been truely allocated
    foreach my $hold (values %Holds) {
	if (!$hold->{allocated}) {
	    $hold->{hostnames} = [];	# Although we delete, there may still be other references to it...
	}
    }
}

sub _hold_timecheck {
    # Called once every 3 seconds.
    # See if any holds have expired; if so delete them
    #_timelog("hold_timecheck $Time\n") if $Debug;
    foreach my $hold (values %Holds) {
	$hold->{expires} ||= ($Time + ($hold->{hold_time}||10));
	if ($Time > $hold->{expires}) {
	    #_timelog("HOST DONE MARK $host $hostname $key EXP $hold->{expires}\n") if $Debug;
	    # Same cleanup below in _exist_traffic
	    _hold_delete ($hold);
	} else {
	    $Exister->pid_request(host=>$hold->{req_hostname}, pid=>$hold->{req_pid});
	}
    }
}

sub _holds_adjust {
    # Adjust loading on all machines to make up for scheduler holds
    _timelog("HOLDS:  ",Data::Dumper::Dumper (\%Holds)) if $Debug;

    # Reset adjusted loads
    foreach my $host ($Hosts->hosts_unsorted) {
	$host->{dynamic}{adj_load} = $host->{dynamic}{report_load};
	$host->{dynamic}{holds} = [];
    }

    # adj_load is the report_load plus any hold_keys allocated on a specific host
    #          plus any hold_keys waiting to finish their scheduling run
    foreach my $hold (values %Holds) {
	foreach my $hostname (@{$hold->{hostnames}}) {
	    my $host = $Hosts->get_host($hostname);
	    if (!$host) {
		# This can happen when we do a hold on a host and that host's reporter
		# then goes down.  It's harmless, as all will be better when it comes back.
		warn "No host $hostname" if $Debug;
	    } else {
		$host->{dynamic}{adj_load} += _hold_load_host_adjusted($hold,$host);
		push @{$host->{dynamic}{holds}}, $hold;
	    }
	}
    }
}

######################################################################

sub _exist_traffic {
    # Handle UDP responses from our $Exister->pid_request calls.
    #_timelog("UDP PidStat in...\n") if $Debug;
    my ($pid,$exists,$onhost) = $Exister->recv_stat();
    return if !defined $pid;
    return if !defined $exists || $exists;   # We only care about known-missing processes
    _timelog("  UDP PidStat PID $onhost:$pid no longer with us.  RIP.\n") if $Debug;
    # We don't maintain a table sorted by pid, as these messages
    # are rare, and there can be many holds per pid.
    foreach my $hold (values %Holds) {
	if ($hold->{req_pid}==$pid && $hold->{req_hostname} eq $onhost) {
	    # Same cleanup above when timer expires
	    _hold_delete ($hold);
	}
    }
}

######################################################################
######################################################################
#### Information to pass up to "rschedule status" for debugging

sub _update_chooinfo {
    my $delta_time = shift;
    # Load information we want to pass up to rschedule for debugging chooser
    # details from a client application
    $ChooInfo{last_command_delay} = $delta_time;
    $ChooInfo{schreqs} = {};
    foreach my $hold (values %Holds) {
	next if !$hold->{schreq};
	$ChooInfo{schreqs}{$hold->hold_key} = $hold;
    }

    # Return all recent messages
    _messages_remove();
    $ChooInfo{slchoosed_messages} = \@Messages;
}

######################################################################
######################################################################
#### Little stuff

sub _timesyslog {
    my $class = shift;
    my $msg = join('',@_);
    _messages_remove();
    push @Messages, [gettimeofday(), $class, $msg];
    if ($Debug) {
	_timelog($msg);
    } else {
	openlog('slchoosed', 'cons,pid', 'daemon');
	syslog($class, $msg);
	closelog();
    }
}

sub _timelog {
    my $msg = join('',@_);
    my ($time, $time_usec) = gettimeofday();
    print Schedule::Load::Hosts::_format_utime($time,$time_usec)." ".$msg;
}

sub _messages_remove {
    # Remove all messages that are too old
    my $expire = time() - LOG_MESSAGE_TIMEOUT();
    while ($#Messages >= 0) {
	my $msg = $Messages[0];
	my $time = $msg->[0];
	if ($time < $expire) {
	    shift @Messages;
	} else {
	    last;
	}
    }
    while ($#Messages >= LOG_MESSAGE_COUNT()) {
	shift @Messages;
    }
}

######################################################################
######################################################################
#### Package return
1;

######################################################################
__END__

=pod

=head1 NAME

Schedule::Load::Chooser - Distributed load choosing daemon

=head1 SYNOPSIS

  use Schedule::Load::Chooser;

  Schedule::Load::Chooser->start(port=>1234,);

=head1 DESCRIPTION

L<Schedule::Load::Chooser> on startup creates a daemon that clients can
connect to using the Schedule::Load package.

=over 4

=item start ([parameter=>value ...]);

Starts the chooser daemon.  Does not return.

=back

=head1 PARAMETERS

=over 4

=item port

The port number of slchoosed.  Defaults to 'slchoosed' looked up via
/etc/services, else 1752.

=item ping_dead_timeout

Seconds after which if a client doesn't respond to a ping, it is considered
dead.

=back

=head1 DISTRIBUTION

The latest version is available from CPAN and from L<http://www.veripool.org/>.

Copyright 1998-2011 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License Version 3 or the Perl Artistic License Version 2.0.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<Schedule::Load>, L<slchoosed>

=cut
