# Schedule::Load::Hosts.pm -- Loading information about hosts
# See copyright, etc in below POD section.
######################################################################

package Schedule::Load::Hosts;
require 5.004;
require Exporter;
@ISA = qw(Exporter);

use Socket;
use POSIX qw (EWOULDBLOCK EINTR EAGAIN BUFSIZ);
use Schedule::Load qw(:_utils);
use Schedule::Load::Hold;
use Schedule::Load::Hosts::Host;
use Schedule::Load::Hosts::Proc;
use Time::localtime;
use Sys::Hostname;

use strict;
use vars qw($VERSION $Debug);
use Carp;

######################################################################
#### Configuration Section

# Other configurable settings.
$Debug = $Schedule::Load::Debug;

$VERSION = '3.064';

######################################################################
#### Globals

######################################################################
#### Creator

sub new {
    @_ >= 1 or croak 'usage: Schedule::Load::Hosts->new ({options})';
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = {
	%Schedule::Load::_Default_Params,
	username=>($ENV{USER}||""),
	#Internal
	@_,};
    bless $self, $class;
    return $self;
}

######################################################################
#### Constructor

sub fetch {
    my $self = shift;
    $self = $self->new(@_) if (!ref($self));
    return if $self->{_fetched} && $self->{_fetched}<0;
    # Erase current structures in case a host goes down
    delete $self->{hosts};
    # Make the request
    $self->_request("get_const_load_proc_chooinfo\n");
    $self->{_fetched} = 1;
    return $self;
}

sub _fetch_if_unfetched {
    my $self = shift;
    $self->fetch() if (!$self->{_fetched});
    return $self;
}
sub kill_cache {
    my $self = shift;
    $self->{_fetched} = 0;
}

sub restart {
    my $self = shift;
    my $params = {
	chooser=>1,
	chooser_if_reporters=>0,
	reporter=>1,
	@_,};
    $self->_request("report_restart\n") if $params->{reporter};
    $self->_request("chooser_restart_if_reporters\n") if $params->{chooser_if_reporters};
    $self->_request("chooser_restart\n") if $params->{chooser} && !$params->{chooser_if_reporters};
}
sub _chooser_close_all {
    my $self = shift;
    $self->_request("chooser_close_all\n");
}

######################################################################
#### Accessors

sub hosts {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts()';
    # Return all hosts - for backward compatibility this is is a sorted accessor
    my @keys = $self->hosts_sorted;
    return (wantarray ? @keys : \@keys);
}

sub hosts_sorted {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts()';
    # Return all hosts
    $self->_fetch_if_unfetched;
    # For speed, we're avoiding the hostname accessor.  Generally don't do this.
    return (sort {($a->{const}{hostname}||"") cmp ($b->{const}{hostname}||"")}  # $a->hostname cmp $b->hostname
	    values %{$self->{hosts}});
}

sub hosts_unsorted {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts()';
    # Return all hosts
    $self->_fetch_if_unfetched;
    return (values %{$self->{hosts}});
}

sub hosts_match {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts_match()';
    my %params = (#classes=>[],		# Passed to Host::host_match
		  #match_cb=>0,		# Passed to Host::host_match
		  #allow_reserved=>1,	# Passed to Host::host_match
		  @_);
    # Return all hosts matching parameters
    $self->_fetch_if_unfetched;
    my @keys;
    foreach my $host ($self->hosts_sorted) {
	push @keys, $host if $host->host_match(%params);
    }
    return (wantarray ? @keys : \@keys);
}

sub schreq_holds {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->schreqs_holds()';
    # Return all hosts matching parameters
    $self->_fetch_if_unfetched;
    my @keys;
    foreach my $hold (values(%{$self->{chooinfo}{schreqs}})) {
	push @keys, $hold;
    }
    return (wantarray ? @keys : \@keys);
}

sub get_host {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->get_host(hostname)';
    my $hostname = shift;

    $self->_fetch_if_unfetched;
    return $self->{hosts}{$hostname};
}

sub classes {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->classes()';

    my %classes = ();
    $self->_fetch_if_unfetched;
    foreach my $host ($self->hosts_sorted) {
	foreach (sort ($host->fields)) {
	    # Ignore classes that are set to 0
	    $classes{$_} = 1 if /^class_/ && $host->get($_);
	}
    }
    my @classes = (keys %classes);
    return (wantarray ? @classes : \@classes);
}

######################################################################
######################################################################
#### Totals across all hosts

sub cpus {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->classes()';
    my %params = (#classes=>[],		# Passed to Host::host_match
		  #match_cb=>0,		# Passed to Host::host_match
		  allow_reserved=>1,	# Passed to Host::host_match
		  @_);
    # Return number of cpus for a given class
    $self->_fetch_if_unfetched;
    my $jobs = 0;
    foreach my $host ($self->hosts_match(%params)) {
	$jobs += $host->cpus();
    }
    return $jobs;
}

sub hostnames {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts()';
    my %params = (#classes=>[],		# Passed to Host::host_match
		  #match_cb=>0,		# Passed to Host::host_match
		  allow_reserved=>1,	# Passed to Host::host_match
		  @_);
    # Return hostnames, potentially matching given classes
    my @hnames;
    foreach my $host ($self->hosts_match(%params)) {
	push @hnames, $host->hostname;
    }
    @hnames = (sort @hnames);
    return (wantarray ? @hnames : \@hnames);
}

sub idle_host_names {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->hosts()';
    my %params = (#classes=>[],		# Passed to Host::host_match
		  #match_cb=>0,		# Passed to Host::host_match
		  allow_reserved=>0,	# Passed to Host::host_match
		  #ign_pctcpu=>0,
		  #by_pctcpu=>0,
		  @_);
    # Return idle hosts, potentially matching given classes
    # Roughly scaled so even powered hosts have even representation

    my @hnames;
    foreach my $host ($self->hosts_match(%params)) {
	my $idleCpus = $host->cpus;
	if ($params{ign_pctcpu}) {
	} elsif ($params{by_pctcpu}) {  # min of adj_load or percentage
	    $idleCpus = $host->cpus;
	    my $adj = (($host->cpus * $host->total_pctcpu / 100) - 0.2);  # 80% used? squeeze another in
	    $adj = 0 if $adj<0;
	    $idleCpus -= $adj;
	} else {
	    $idleCpus = $host->free_cpus;
	}
	for (my $c=0; $c<$idleCpus; $c++) {
	    push @hnames, $host->hostname;
	}
    }
    @hnames = (sort @hnames);
    return (wantarray ? @hnames : \@hnames);
}

######################################################################
######################################################################
#### Low level prints

sub digit {
    my $host = shift;
    my $field = shift;
    return " " if !$host->exists($field);
    my $val = $host->get($field);
    return " " if !$val;
    return "*" if $val>9;
    return $val;
}

sub _format_time {
    my $value = shift || 0;
    my $t = localtime($value);
    return sprintf("%04d/%02d/%02d %02d:%02d:%02d", $t->year+1900,$t->mon+1,$t->mday,$t->hour,$t->min,$t->sec);
}

sub _format_utime {
    my $time = shift;
    my $time_usec = shift;
    my ($sec,$min,$hour,$mday,$mon) = CORE::localtime($time);
    return sprintf ("[%02d/%02d %02d:%02d:%02d.%06d]",
		    $mon+1, $mday, $hour, $min, $sec, $time_usec);
}

sub _hostname_width {
    my $hosts = shift;
    my $hostwidth = 4;  # For 'HOST' header
    foreach my $host ($hosts->hosts_sorted) {
	$hostwidth = length($host->hostname) if $hostwidth < length($host->hostname);
    }
    return $hostwidth;
}

######################################################################
######################################################################
#### Table printing

sub format_table {
    shift;  # Ignored; just so can object call it
    my %params = (formats => [],
		  data => [],
		  @_);
    # Given table with row of formats, where ^ is the width of the column,
    # return string with data formatted.
    my @widths;
    foreach my $rowref (@{$params{data}}) {
	for (my $col=0; $col<=$#{$rowref}; $col++) {
	    $rowref->[$col] = '' if !defined $rowref->[$col];
	    $widths[$col] = length($rowref->[$col])
		if (($widths[$col]||0) < length($rowref->[$col]));
	}
    }
    my @formats = (@{$params{formats}});
    for (my $col=0; $col<=$#formats; $col++) {
	my $width = $widths[$col] || 1;
	$formats[$col] =~ s!\^!$width!;
    }
    my @out;
    foreach my $rowref (@{$params{data}}) {
	for (my $col=0; $col<=$#{$rowref}; $col++) {
	    push @out, ' ' if $col>0;
	    push @out, sprintf($formats[$col], $rowref->[$col]);
	}
	push @out, "\n";
    }
    return join ("", @out);
}

######################################################################
######################################################################
#### Information printing

sub print_hosts {
    my $hosts = shift;
    # Overall machine status
    my @fmts = ("%-^s", " %^s", "%^s",  "%^s%%",  "%^s",  "%^s",  "%^s"," %s");
    my @data = ["HOST", "CPUs", "FREQ", "TotCPU", "LOAD", "RATE", "RL", "ARCH/OS"];
    foreach my $host ($hosts->hosts_sorted) {
	my $ostype = $host->archname ." ". $host->osvers;
	$ostype = "Reserved: ".$host->reserved if ($host->reserved);
	push @data, [$host->hostname,
		     $host->cpus_slash,
		     $host->max_clock,
		     sprintf("%3.1f", $host->total_pctcpu),
		     sprintf("%2.2f", $host->adj_load),
		     $host->rating_text,
		     ( ($host->reservable?"R":" ")
		       . digit($host,'load_limit')),
		     $ostype,
		     ];
    }
    return $hosts->format_table(formats=>\@fmts, data=>\@data);
}

sub print_holds {
    my $hosts = shift;
    # Holding commands
    my %holdlist;
    my $i=0;
    foreach my $host ($hosts->hosts_sorted) {
	foreach my $hold ($host->holds) {
	    $i++;
	    my $key = $hold->req_user."_".$hold->req_hostname."_".$hold->req_pid
		."_".$hold->hold_key."_".$host->hostname."_".$i;
	    $holdlist{$key} = {hold => $hold,
			       host => $host,
			       code => ($hold->allocated?"A":"S"),};
	}
    }
    foreach my $hold ($hosts->schreq_holds) {
	my $key = $hold->req_user."_".$hold->req_hostname."_".$hold->req_pid
	    ."_".$hold->hold_key."_CHOO_".$i;
	$holdlist{$key} = {hold => $hold,
			   host => undef,
		           code => "P",};
    }
    my @fmts = ("%-^s", " %-^s", " %^s",  "%^s", "%^s","%^s","%^s", "%-^s",    " %-s");
    my @data = ["USER", "UHOST", "UPID", "PRI", "L",  "S",  "WAIT", "ON_HOST", "COMMENT"];
    foreach my $key (sort (keys %holdlist)) {
	my $hold = $holdlist{$key}{hold};
	my $host = $holdlist{$key}{host};
	push @data, [$hold->req_user,
		     $hold->req_hostname,
		     $hold->req_pid,
		     $hold->req_pri,
		     $hold->hold_load,
		     $holdlist{$key}{code},
		     Schedule::Load::Hosts::Proc->format_hhmm(time() - $hold->req_time),
		     #
		     ($host ? $host->hostname : "{pending}"),
		     $hold->comment,
		     ];
    }
    return $hosts->format_table(formats=>\@fmts, data=>\@data);
}

sub print_status {
    my $hosts = shift;
    # Daemon status, mostly for debugging
    $hosts->_fetch_if_unfetched;
    my $out = "";
    {
	my @fmts = ("%-^s",    "%^s",     "%-^s",      "%^s",   " %-s");
	my @data = ["CHOOSER", "VERSION", "CONNECTED", "DELAY", "DAEMON STATUS"];
	push @data, [$hosts->{chooinfo}{slchoosed_hostname},
		     ($hosts->{chooinfo}{slchoosed_version}||"?"),
		     _format_time($hosts->{chooinfo}{slchoosed_connect_time}||0),
		     sprintf("%2.3f",$hosts->{chooinfo}{last_command_delay}||0),
		     $hosts->{chooinfo}{slchoosed_status}];
	$out .= $hosts->format_table(formats=>\@fmts, data=>\@data);
	$out .= "\n";
    }
    {
	my @fmts = ("%-^s",    "%-^s", "%-^s", "%-^s",);
	my @data = ["CHOOSER", "DATE", "LEVEL", "MESSAGE"];
	my $msgs = $hosts->{chooinfo}{slchoosed_messages}||[];
	foreach my $msg (@$msgs) {
	    my $text = $msg->[3];  $text =~ s!\n$!!;
	    push @data, [$hosts->{chooinfo}{slchoosed_hostname},
			 _format_utime($msg->[0], $msg->[1]),

			 $msg->[2], $text];
	}
	$out .= $hosts->format_table(formats=>\@fmts, data=>\@data);
	$out .= "\n";
    }
    {
	my @fmts = ("%-^s", "%^s%%", "%^s",  "%^s",  "%^s",      "%-^s",    "%-^s",       "%^s",   " %-s");
	my @data = ["HOST", "TotCPU","LOAD", "RATE", "REPORTER", "VERSION", "CONNECTED", "DELAY", "DAEMON STATUS"];
	foreach my $host ($hosts->hosts_sorted) {
	   push @data, [$host->hostname,
			sprintf("%3.1f", $host->total_pctcpu),
			sprintf("%2.2f", $host->adj_load),
			$host->rating_text,
			$host->slreportd_hostname,
			($host->get_undef('slreportd_version')||"?"),
			_format_time($host->slreportd_connect_time||0),
			(defined $host->slreportd_delay ? sprintf("%2.3f",$host->slreportd_delay) : "?"),
			$host->slreportd_status,
			];
	}
	$out .= $hosts->format_table(formats=>\@fmts, data=>\@data);
    }
    return $out;
}

sub print_top {
    my $hosts = shift;
    # Top processes
    my @fmts = ("%-^s", "%^s", "%-^s", "%^s",  "%^s", "%-^s",  "%^s", "%^s%%"," %-s");
    my @data = ["HOST", "PID", "USER", "NICE", "MEM", "STATE", "RUNTM", "CPU","COMMAND"];
    foreach my $host ($hosts->hosts_sorted) {
	foreach my $p ( sort {$b->pctcpu <=> $a->pctcpu}
			@{$host->top_processes} ) {
	    next if ($p->pctcpu < $hosts->{min_pctcpu});
	    my $comment = ($p->exists('cmndcomment')? $p->cmndcomment:$p->fname);
	    push @data, [$host->hostname,
			 $p->pid,
			 $p->uname,		$p->nice0,
			 int(($p->size||0)/1024/1024)."M",
			 $p->state,		$p->time_hhmm,
			 sprintf("%3.1f", $p->pctcpu),
			 substr ($comment,0,18),
			 ];
	}
    }
    return $hosts->format_table(formats=>\@fmts, data=>\@data);
}

sub print_loads {
    my $hosts = shift;
    # Top processes
    my @fmts = ("%-^s", "%-^s", "%^s", "%-^s", "%^s", "%^s",   "%^s%%", " %-s");
    my @data = ["HOST", "REQHOST", "PID", "USER", "NIC", "RUNTM", "CPU",   "COMMAND"];
    foreach my $host ($hosts->hosts_sorted) {
	foreach my $p ( sort {$b->pctcpu <=> $a->pctcpu}
			@{$host->top_processes} ) {
	    my $comment = ($p->exists('cmndcomment')? $p->cmndcomment:$p->fname);
	    push @data, [$host->hostname,
			 ($p->exists('req_hostname')? $p->req_hostname : ''),
			 $p->pid,
			 $p->uname,
			 $p->nice,
			 $p->time_hhmm,
			 sprintf("%3.1f", $p->pctcpu),
			 $comment,
			 ];
	}
    }
    return $hosts->format_table(formats=>\@fmts, data=>\@data);
}

sub print_kills {
    my $hosts = shift;
    my $params = {
	signal=>0,
	@_,};
    # Top processes
    my @fmts = ("ssh %-^s"," kill %s","%^s"," #   %-^s","%-^s","%^s","%^s%%","%-s");
    my @data;
    foreach my $host ($hosts->hosts_sorted) {
	foreach my $p ( sort {$b->pctcpu <=> $a->pctcpu}
			@{$host->top_processes} ) {
	    my $comment = ($p->exists('cmndcomment')? $p->cmndcomment:$p->fname);
	    push @data, [($p->exists('req_hostname')? $p->req_hostname : $host->hostname),
			 ($params->{signal}?"-$params->{signal} ":""),
			 $p->pid,
			 $host->hostname,
			 $p->uname,		$p->time_hhmm,
			 sprintf("%3.1f", $p->pctcpu),
			 $comment,
			 ];
	}
    }
    return $hosts->format_table(formats=>\@fmts, data=>\@data);
}

sub print_classes {
    my $hosts = shift;
    # Host classes
    my $out = "";

    my @classes = (sort ($hosts->classes()));
    my $classnum = 0;
    my %class_letter;
    my %class_numeric;
    my @col_width;
    foreach my $class (@classes) {
	$class_letter{$class} = chr($classnum%26+ord("a"));
	$col_width[$classnum] = 1;
	foreach my $host ($hosts->hosts_sorted) {
	    my $val = $host->get_undef($class);
	    if ($val) {
		$col_width[$classnum] = length $val if $col_width[$classnum] < length $val;
		$class_numeric{$class} = 1 if $val>1;
	    }
	}
	$classnum++;
    }

    my @fmts = ("%-^s", "%-s");
    my @data;

    my $classes = $classnum;
    $classnum = 0;
    foreach my $class (@classes) {
	my $out;
	for (my $prtclassnum = 0; $prtclassnum<$classnum; $prtclassnum++) {
	    $out .= (" "x$col_width[$prtclassnum])."|";
	}
	$out .= (" "x$col_width[$classnum]).$class_letter{$class};
	for (my $prtclassnum = $classnum+1; $prtclassnum<$#classes; $prtclassnum++) {
	    $out .= ("-"x$col_width[$prtclassnum])."-";
	}
	$out.= "-$class_letter{$class}" if $classnum!=$classes-1;
	$out.=sprintf ("- %s", $class);
	$classnum++;
	push @data, [(($classnum==$classes-1)?"HOST":""), $out];
    }
    foreach my $host ($hosts->hosts_sorted) {
	my $out;
	$classnum = 0;
	foreach my $class (@classes) {
	    my $val = $host->get_undef($class);
	    my $chr = ".";
	    if ($val && ($val > 1 || $class_numeric{$class})) {
		$chr = $val;
	    } elsif ($val) {
		$chr = $class_letter{$class};
	    } else {
		$chr = ".";
	    }
	    $out .= sprintf (" %$col_width[$classnum]s", $chr);
	    $classnum++;
	}
	push @data, [$host->hostname, $out];
    }
    return $hosts->format_table(formats=>\@fmts, data=>\@data);
}

######################################################################
######################################################################
#### User requests

sub cmnd_comment {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->cmnd_comment)';
    my $params = {
	host=>hostname(),
	comment=>undef,
	uid=>$<,
	pid=>$$,
	@_,};

    print __PACKAGE__."::cmnd_comment($params->{comment})\n" if $Debug;
    (defined $params->{comment}) or croak 'usage: cmnd_comment needs comment parameter)';
    $self->_request(_pfreeze( 'report_fwd_comment', $params, $Debug));
}

######################################################################
######################################################################
#### Guts: Sending and receiving messages

sub _open {
    my $self = shift;

    my @hostlist = ($self->{dhost});
    @hostlist = @{$self->{dhost}} if (ref($self->{dhost}) eq "ARRAY");

    my $fh;
    foreach my $host (@hostlist) {
	print "Trying host $host\n" if $Debug;
	$fh = Schedule::Load::Socket->new(
					  PeerAddr  => $host,
					  PeerPort  => $self->{port},
					  );
	if ($fh) {
	    print "Opened $host\n" if $Debug;
	    last;
	}
    }
    if (!$fh) {
	if (defined $self->{print_down}) {
	    &{$self->{print_down}} ($self);
	    return;
	}
	croak "%Error: Can't locate slchoosed server on " . (join " or ", @hostlist), " $self->{port}\n"
	    . "\tYou probably need to run slchoosed\n$self->_request(): Stopped";
    }
    $self->{_fh} = $fh;
    $self->{_inbuffer} = "";
}

sub _request {
    my $self = shift;
    my $cmd = shift;
    my %params = (req_retries => ($self->{req_retries}||3),
		  req_retry_delay => ($self->{req_retry_delay}||20),
		  );

    for (my $retry=0; $retry<$params{req_retries}; $retry++) {
	my $done = $self->_request_try($cmd);
	if ($done) {
	    last;
	} else {
	    print "RETRY\n" if $Debug;
	    sleep $params{req_retry_delay};
	}
    }
}

sub _request_try {
    my $self = shift;
    my $cmd = shift;

    if (!defined $self->{_fh}) {
	$self->_open;
    }
    my $fh = $self->{_fh};

    print "_request-> $cmd\n" if $Debug;
    $fh->send_and_check($cmd);

    my $done;
    my $eof;
    my $completed;
    while (!$done) {
	if ($self->{_inbuffer} !~ /\n/) {
	    my $data = '';
	    $!=undef;
	    my $rv = $fh->sysread($data, POSIX::BUFSIZ, 0);
	    $self->{_inbuffer} .= $data;
	    $eof = 1 if (!defined $rv || (length $data == 0))
		&& ($! != POSIX::EINTR && $! != POSIX::EAGAIN);
	    $done ||= $eof;
	}

	while ($self->{_inbuffer} =~ s/^([^\n]*)\n//) {
	    my $line = $1;
	    chomp $line;
	    print "GOT $line\n" if $Debug;

	    my ($cmd, $params) = _pthaw($line, $Debug);
	    next if $line =~ /^\s*$/;
	    if ($cmd eq "DONE") {
		$done = 1;
		$completed = 1;
	    } elsif ($cmd eq "host") {
		$self->_host_load ($params);
	    } elsif ($cmd eq "schrtn") {
		$self->{_schrtn} = $params;
	    } elsif ($cmd eq "chooinfo") {
		$self->{chooinfo} = $params;
	    } else {
		warn "%Warning: Bad Schedule::Load server response: $line\n";
		$line = undef;
	    }
	}
    }
    if ($eof || !$fh->connected()) {
	$fh->close();
	undef $self->{_fh};
    }
    print "_request DONE-> $cmd\n" if $Debug;
    return $completed;
}

######################################################################
#### Loading

sub _host_load {
    my $self = shift;
    my $params = shift;
    # load/proc command (also used by Chooser)
    # Load a Hosts::Host hash, bless, and load given field
    # Move perhaps to Hosts::Host->new.

    my $hostname = $params->{hostname};
    my $field = $params->{type};

    $self->{hosts}{$hostname}{$field} = $params->{table};
    bless $self->{hosts}{$hostname}, "Schedule::Load::Hosts::Host";
}

######################################################################
######################################################################
#### Utilities

sub ping {
    my $self = shift;
    my @params = @_;
    my $ok = eval {
	$self->fetch(@params);
    };
    return $ok;
}

######################################################################
#### Package return
1;

######################################################################
__END__

=pod

=head1 NAME

Schedule::Load::Hosts - Return host loading information across a network

=head1 SYNOPSIS

    use Schedule::Load::Hosts;

    my $hosts = Schedule::Load::Hosts->fetch();
    $hosts->print_machines();
    $hosts->print_top();

    # Overall machine status
    my $hosts = Schedule::Load::Hosts->fetch();
    (my $FORMAT =    "%-12s    %4s     %4s   %6s%%       %5s    %s\n") =~ s/\s\s+/ /g;
    printf ($FORMAT, "HOST", "CPUs", "FREQ", "TotCPU", "LOAD", "ARCH/OS");
    foreach my $host ($hosts->hosts_sorted) {
	printf STDOUT ($FORMAT,
		       $host->hostname,
		       $host->cpus_slash,
		       $host->max_clock,
		       sprintf("%3.1f", $host->total_pctcpu),
		       sprintf("%2.2f", $host->adj_load),
		       $host->archname ." ". $host->osvers,
		       );
    }

    # Top processes
    (my $FORMAT =    "%-12s   %6s    %-10s     %-5s    %6s     %5s%%    %s\n") =~ s/\s\s+/ /g;
    printf ($FORMAT, "HOST", "PID", "USER",  "STATE", "RUNTM", "CPU","COMMAND");
    foreach my $host ($hosts->hosts_sorted) {
	foreach $p ($host->top_processes) {
	    printf($FORMAT,
		   $host->hostname,
		   $p->pid,		$p->uname,
		   $p->state,		$p->time_hhmm,
		   $p->pctcpu,		$p->fname);
	}
    }

=head1 DESCRIPTION

This package provides information about host loading and top processes
from many machines across a entire network.

=over 4

=item $self->fetch ()

Fetch the data structures from across the network.  This also creates
a new object.  Accepts the port and host parameters.

=item $self->format_table(formats=>[...], data=>[...]);

Used internally by the print routines, but may be useful for external use
also.  Return a table as a string.  Named format argument must be an array
reference containing sprintf strings, plus '^' may be used as the width of
the widest data column.  Named data argument must be two dimmensional array
reference of the data table to be printed.

=item $self->restart ()

Restart all daemons, loading their code from the executables again.  Use
sparingly.  chooser parameter if true (default) restarts chooser, reporter
parameter if true (default) restarts reporter.

=item $self->hosts ()

Returns the host objects in name sorted order, accessible with
L<Schedule::Load::Hosts::Host>.  In an array context, returns a list; In a
a scalar context, returns a reference to a list.  This function is
historical, using hosts_sorted or hosts_unsorted is faster.

=item $self->hosts_sorted ()

Returns array of host objects in name sorted order, accessible with
L<Schedule::Load::Hosts::Host>.

=item $self->hosts_unsorted ()

Returns array of host objects in unsorted order, accessible with
L<Schedule::Load::Hosts::Host>.

=item $self->hosts_match (...)

Returns L<Schedule::Load::Hosts::Host> objects for every host that matches
the specified criteria.  Criteria are named parameters, as described in
Schedule::Load::Schedule, of the following: classes specifies an arrayref
of allowed classes.  match_cb is a routine returning true if this host
matches.  allow_reserved=>0 disables returning of reserved hosts.

=item $self->idle_host_names (...)

Returns a list of host cpu names which are presently idle.  Multiple
free CPUs on a given host will result in that name being returned multiple
times.

=item $self->ping

Return true if the slchoosed server is up.

=item $self->get_host ($hostname)

Returns a reference to a host object with the specified hostname,
or undef if not found.

=item $self->classes ()

Returns all class_ variables under all hosts.  In an array context, returns
a list; In a a scalar context, returns a reference to a list.

=item $self->print_classes

Returns a string with the list of machines and classes that may run on them
in a printable format.

=item $self->print_hosts

Returns a string with the list of host machines and loading in a printable
format.

=item $self->print_top

Returns a string with the top jobs on all machines in a printable format,
ala the L<top> program.

=item $self->print_loads

Returns a string with the top jobs command lines, including any jobs with
a fixed loading.

=back

=head1 PARAMETERS

=over 4

=item dhost

List of daemon hosts that may be running the slchoosed server.  The second
host is only used if the first is down, and so on down the list.

=item port

The port number of slchoosed.  Defaults to 'slchoosed' looked up via
/etc/services, else 1752.

=back

=head1 DISTRIBUTION

The latest version is available from CPAN and from L<http://www.veripool.org/>.

Copyright 1998-2011 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License Version 3 or the Perl Artistic License Version 2.0.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<Schedule::Load>, L<rschedule>

L<Schedule::Load::Hosts::Host>, L<Schedule::Load::Hosts::Proc>

=cut
