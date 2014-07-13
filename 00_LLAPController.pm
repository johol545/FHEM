package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
if( $^O =~ /Win/ ) {
	require Win32::SerialPort;
} else {
	require Device::SerialPort;
} 

sub LLAPController_Read($);
sub LLAPController_ReadAnswer($$);
sub LLAPController_Ready($);
sub LLAPController_SendQueueHandler($);
sub LLAPController_Write($$$$$);

my $ackTimeout = 3; #seconds

sub LLAPController_Initialize($) {
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

# Provider
  $hash->{ReadFn}  = "LLAPController_Read";
  $hash->{WriteFn} = "LLAPController_Write";
  $hash->{ReadyFn} = "LLAPController_Ready";
  $hash->{Clients} = ":LLAPDevice:";
  my %matchList= (
    "1:LLAPDevice"   => "^LLAPDevice:",
  );
  $hash->{MatchList} = \%matchList;

# Normal devices
  $hash->{DefFn}   = "LLAPController_Define";
  $hash->{UndefFn} = "LLAPController_Undef";
  $hash->{GetFn}   = "LLAPController_Get";
  $hash->{SetFn}   = "LLAPController_Set";
  $hash->{AttrList}= "do_not_notify:1,0 dummy:1,0 blockSenderID:own,no";
}

# Define
sub
LLAPController_Define($$)
{
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def);
	my $name = $a[0];

	return "LLAPController: wrong syntax, correct is: define <name> LLAPController " .
		"{devicename[\@baudrate]|ip:port|none}" if(@a != 3);

	DevIo_CloseDev($hash);
	my $dev  = $a[2];
	$hash->{DeviceName} = $dev;
	$hash->{cnt} = 0;
	$hash->{pairmode} = 0;
	$hash->{sendQueue} = [];
	$hash->{BUFFER} = "";

	if($dev eq "none") {
	    Log3 undef, 1, "LLAPController $name device is none, commands will be echoed only";
		$attr{$name}{dummy} = 1;
		return undef;
	}
  
	my $ret = DevIo_OpenDev($hash, 0, undef);
	return $ret;
}

# Undef
sub
LLAPController_Undef($$)
{
	my ($hash, $arg) = @_;
	my $name = $hash->{NAME};
	
	foreach my $d (sort keys %defs) {
		if(defined($defs{$d}) &&
		   defined($defs{$d}{IODev}) &&
		   $defs{$d}{IODev} == $hash)
		{
			my $lev = ($reread_active ? 4 : 2);
			Log3 $name, $lev, "LLAPController deleting port for $d";
			delete $defs{$d}{IODev};
		}
	}
	DevIo_CloseDev($hash); 
	return undef;
}

# Send
sub
LLAPController_Write($$$$$)
{
  	my ($hash, $dst, $cmd, $val, $ack) = @_;
  	my $callbackParam = undef;

  	my $packet = "a" . $dst . $cmd . $val;
	$packet .= "-" x ( 12 - length($packet) );  # Add - to the message to make it 12 chars long

  Log GetLogLevel($hash->{NAME}, 5), "LLAPController_Send: enqueuing $packet";
  my $timeout = gettimeofday()+$ackTimeout;
  my $aref = $hash->{sendQueue};
  push(@{$aref},  { "packet" => $packet,
                    "dst" => $dst,
                    "cmd" => $cmd,
					"val" => $val,
  					"ack" => $ack,
                    "time" => $timeout,
                    "sent" => "0",
                  });

  #Call LLAPController_SendQueueHandler if we just enqueued the only packet
  #otherwise it is already in the InternalTimer list
  LLAPController_SendQueueHandler($hash) if(@{$hash->{sendQueue}} == 1);
  return undef;
}


#This can be called for two reasons:
#1. @sendQueue was empty, LLAPController_Write added a packet and then called us
#2. We sent a packet from @sendQueue and know the ackTimeout is over.
#   The packet my still be in @sendQueue (timed out) or removed when the Ack was received.
# TODO: Some kind of sending credits should probably be implemented due to legal restrictions
sub
LLAPController_SendQueueHandler($)
{
	my $hash = shift;
	Log GetLogLevel($hash->{NAME}, 5), "LLAPController_SendQueueHandler: " . @{$hash->{sendQueue}} . " items in queue";
	return if(!@{$hash->{sendQueue}}); #nothing to do
	
	my $timeout = gettimeofday(); #reschedule immediatly
	my $packet = $hash->{sendQueue}[0];
	
	if($packet->{sent} == 0) {  # Send message
		# TODO: Fix padding etc?
		DevIo_SimpleWrite($hash, $packet->{packet}, 0);
		Log3 $hash->{NAME}, 5, "LLAPController sent: $packet->{packet}";
		$packet->{sent} = 1;
		$packet->{sentTime} = gettimeofday();
		$timeout += 0.5; #recheck for Ack
	} elsif($packet->{sent} == 1) { # Already sent it, got no Ack
		if( $packet->{sentTime} + $ackTimeout < gettimeofday() ) {
			# ackTimeout exceeded
			Log 2, "LLAPController_SendQueueHandler: Missing ack from $packet->{dst} for $packet->{packet}";
			splice @{$hash->{sendQueue}}, 0, 1; #Remove from array
			readingsSingleUpdate($hash, "packetsLost", ReadingsVal($hash->{NAME}, "packetsLost", 0) + 1, 1);
		} else {
			# Recheck for Ack
			$timeout += 0.5;
		}
	} elsif( $packet->{sent} == 2 ) { #Got ack
		Dispatch($hash, "LLAPDevice:$packet->{dst}:$packet->{receivedAck}", undef);
		splice @{$hash->{sendQueue}}, 0, 1; #Remove from array
	} else {
		Log 2, "LLAPController_SendQueueHandler: Unknown status $packet->{sent} for $packet->{packet}";
	}

	return if(!@{$hash->{sendQueue}}); #everything done
	InternalTimer($timeout, "LLAPController_SendQueueHandler", $hash, 0);
}

sub
LLAPController_ReceiveAck($$$)
{
	my ($hash, $dst, $cmd) = @_;
	foreach my $packet (@{$hash->{sendQueue}}) {
		my $regex = "^" . $packet->{ack} . "-*\$";
		if($packet->{sent} == 1 && $packet->{dst} eq $dst && $cmd =~ m/$regex/) {
			$packet->{sent} = 2;  # Sent = 2: Received Ack.
			if($cmd =~ m/($packet->{ack})-*/) {
				$packet->{receivedAck} = $1;
				Log 5, "LLAPController_ReceiveAck: $dst$cmd detected as Ack";
			}
			return 2;
		}
	}
	return undef;
}




# Read
# called from the global loop, when the select for hash->{FD} reports data
sub
LLAPController_Read($)
{
	my ($hash) = @_;
	
	my $buf = DevIo_SimpleRead($hash);
	return "" if(!defined($buf));
	
	my $name = $hash->{NAME};
	# my $lastID = hex $hash->{LastID};
	
	my $data = $hash->{BUFFER} . $buf;
	Log3 $name, 5, "LLAPController $name RAW reading: $data";
	
	# DEBUG: Echo data back
	# DevIo_SimpleWrite($hash, $data, 0);

	# TODO: Perlify?
	if(index($data, "a") != 0) {
		Log3 $name, 5, "LLAPController $name discarded data prior to start of message: " . substr($data, index($data, "a"));
	}
	
 	# TODO: Perlify?
	my @commands = $data =~ m/(a[^a]*)/g;
	$hash->{BUFFER} = "";
	for(my $i = 0; $i < scalar (@commands); $i++) {
		#m/^(.)(.........)(.*)/) { 
		if($commands[$i] =~ m/^a([A-Z-#@\?\\\*]{2})([\x20-\x5F]{9})([\s\S]*)/) {
			my ($id, $msg, $garbage) = ($1, $2, $3);
			Log3 $name, 5, "LLAPController $name discarding garbage input data: $garbage" unless ($garbage eq "");
			Log3 $name, 5, "LLAPController $name received valid command: $id$msg";
			if(LLAPController_ReceiveAck($hash, $id, $msg)) {
				LLAPController_SendQueueHandler($hash);
			} else {
				#TODO: What are addvals?
				#my %addvals = undef;
				#Dispatch($hash, "LLAPDevice:$id:$msg", \%addvals);

				# The message is not an ack so send one
				if($msg eq "STARTED--") {
					DevIo_SimpleWrite($hash, "a" . $id . "ACK------", 0);
				}
				Dispatch($hash, "LLAPDevice:$id:$msg", undef);
			}
		} else {
			if($i < scalar(@commands) -1 || length($commands[$i]) >= 12) {
				Log3 $name, 5, "LLAPController $name received invalid command $commands[$i] $i " . scalar(@commands);
			} else {
				# If it's the last part, maybe we haven't received the full command yet. Save for later.
				$hash->{BUFFER} = $commands[$i];
			}
		}
	}
}

# Ready
sub
LLAPController_Ready($)
{
  my ($hash) = @_;

  return DevIo_OpenDev($hash, 1, undef)
                if($hash->{STATE} eq "disconnected");

  # This is relevant for windows/USB only
  my $po = $hash->{USBDev};
  my ($BlockingFlags, $InBytes, $OutBytes, $ErrorFlags) = $po->status;
  return ($InBytes>0);
}

# Available get commands
# TODO: Add more commands
my %getcommands = (
 "APVER",
 "BATT",
);

# Get
sub
LLAPController_Get($@)
{
#   my ($hash, @a) = @_;
#   my $name = $hash->{NAME};

#   return "\"get $name\" needs one parameter" if(@a != 2);
#   my $cmd = $a[1];
#   my ($err, $msg);

#   return "Unknown argument $cmd, choose one of " .
#       join(" ", sort keys %getcommands) if(!defined($cmd));

#   LLAPController_Write($hash, "", $cmd, undef);

#   ($err, $msg) = LLAPController_ReadAnswer($hash, "get $cmd");

#   if($err) {
#     #Log 1, $err;
# # TODO: Why doesn't this work:
# #    Log3 undef, 1, $err;
#     return $err;
#   }
#   $hash->{READINGS}{$cmd}{VAL} = $msg;
#   $hash->{READINGS}{$cmd}{TIME} = TimeNow();
#   return $msg;
}

# Available set commands
# TODO: Add more commands and fix regex for the ones already specified
my %setcommands = (
#  Command => Arg syntax regexo
  "CHDEVID"   => "0[0-1]",
);

# Set
sub
LLAPController_Set($@)
{
# 	my ($hash, @a) = @_;
# 	my $name = $hash->{NAME};
	
# 	return "\"set $name\" needs at least one parameter" if(@a < 2);
# 	my $cmd = $a[1];
# 	my $arg = $a[2];
# 	my ($err, $msg);
	
# 	if(!$setcommands{$cmd}) {
# 		return "Unknown argument $cmd, choose one of ".join(" ", sort(keys(%setcommands)))
# 	}
# 	my $cmdhash = $setcommands{$cmd};

#  # TODO: Rename variables?
#  my $cmdHex = $cmdhash->{cmd};
#  my $argre = $cmdhash->{arg};
#  if($argre) {
#    return "Argument needed for set $name $cmd ($argre)" if(!defined($arg));
#    return "Argument does not match the regexp ($argre)"
#      if($arg !~ m/$argre/i);
#    $cmdHex .= $arg;
#  }

#  # TODO: Check padding
#  $cmdHex .= "-"x(9-length($cmdHex));  # Padding with -
#  # 	my ($hash, $dst, $cmd, $val, $ack) = @_;
# # LLAPController_Write($hash, "", $cmdHex);
#  ($err, $msg) = LLAPController_ReadAnswer($hash, "get $cmd");

#  if($err) {
#    #Log 1, $err;
#    Log3 undef, 1, $err;
#    return $err;
#  }
# 	return $msg;
	return undef;
}


# ReadAnswer
sub
LLAPController_ReadAnswer($$)
{
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  return ("No FD", undef)
        if(!$hash || ($^O !~ /Win/ && !defined($hash->{FD})));

  my ($data, $rin, $buf) = ("", "", "");
  my $to = 3;  # 3 seconds timeout
  # TODO: Some magic going on here?
  for(;;) {
    if($^O =~ m/Win/ && $hash->{USBDev}) {
      $hash->{USBDev}->read_const_time($to*1000); # set timeout (ms)
      # Read anstatt input sonst funzt read_const_time nicht.
      $buf = $hash->{USBDev}->read(999);          
      return ("$name Timeout reading answer for $arg", undef)
        if(length($buf) == 0);

    } else {
      return ("Device lost when reading answer for $arg", undef)
        if(!$hash->{FD});

      vec($rin, $hash->{FD}, 1) = 1;
      my $nfound = select($rin, undef, undef, $to);
      if($nfound < 0) {
        next if ($! == EAGAIN() || $! == EINTR() || $! == 0);
        my $err = $!;
        DevIo_Disconnected($hash);
        return("LLAPController_ReadAnswer $err", undef);
      }
      return ("Timeout reading answer for $arg", undef)
        if($nfound == 0);
      $buf = DevIo_SimpleRead($hash);
      return ("No data", undef) if(!defined($buf));

    }

    if(defined($buf)) {
      $data .= uc(unpack('H*', $buf));
      Log3 $name, 5, "LLAPController RAW ReadAnswer: $data";

      if(length($data) > 12) {
          return ("$arg: Bogus answer received: $data", undef)
  			  # TODO: Fix the regex
  		  if($data !~ m/^a(..)(.........)/);
          $hash->{BUFFER} = substr($data, 13);
      }
    }
  }
}

1;

=pod
=begin html

<a name="TCM"></a>
<h3>TCM</h3>
<ul>
  The TCM module serves an USB or TCP/IP connected TCM120 or TCM310 EnOcean
  Transceiver module. These are mostly packaged together with a serial to USB
  chip and an antenna, e.g. the BSC BOR contains the TCM120, the <a
  href="http://www.enocean.com/de/enocean_module/usb-300-oem/">USB 300</a> from
  EnOcean and the EUL from busware contains a TCM310. See also the datasheet
  available from <a href="http://www.enocean.com">www.enocean.com</a>.
  <br>
  As the TCM120 and the TCM310 speak completely different protocols, this
  module implements 2 drivers in one. It is the "physical" part for the <a
  href="#EnOcean">EnOcean</a> module.<br><br>
  Please note that EnOcean repeaters also send Fhem data telegrams again. Use
  <code>attr &lt;name&gt; <a href="#blockSenderID">blockSenderID</a> own</code>
  to block receiving telegrams with TCM SenderIDs.<br>
  The address range used by your transceiver module, can be found in the
  parameters BaseID and LastID.
  <br><br>
  The transceiver moduls do not always support all commands. The supported range
  of commands depends on the hardware and the firmware version. A firmware update
  is usually not provided.
  <br><br>

  <a name="TCMdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; TCM [120|310] &lt;device&gt;</code> <br>
    <br>
    First you have to specify the type of the EnOcean Transceiver Chip, i.e
    either 120 for the TCM120 or 310 for the TCM310.<br><br>
    <code>device</code> can take the same parameters (@baudrate, @directio,
    TCP/IP, none) like the <a href="#CULdefine">CUL</a>, but you probably have
    to specify the baudrate: the TCM120 should be opened with 9600 Baud, the
    TCM310 with 57600 baud.<br>
    Example:
    <ul><code>
      define BscBor TCM 120 /dev/ttyACM0@9600<br>
      define TCM310 TCM 310 /dev/ttyACM0@57600<br>
      define TCM310 TCM 310 COM1@57600 (Windows)<br>
    </code></ul>

  </ul>
  <br>

  <a name="TCMset"></a>
  <b>Set</b><br>
  <ul><b>TCM 120</b><br>
    <li>idbase [FF800000 ... FFFFFF80]<br>
      Set the BaseID.<br>
      Note: The firmware executes this command only up to then times to prevent misuse.</li>
    <li>modem_off<br>
      Deactivates TCM modem functionality</li>
    <li>modem_on [0000 ... FFFF]<br>
      Activates TCM modem functionality and sets the modem ID</li>
    <li>pairForSec &lt;t/s&gt;<br>
      Set Fhem in teach-in mode.<br>
      The command is only required to teach-in bidirectional actuators
      e. g. EEP 4BS, RORG A5-20-01 (Battery Powered Actuator),
      see <a href="#pairForSec"> Bidirectional Teach-In / Teach-Out</a>.</li>
    <li>reset<br>
      Reset the device</li>
    <li>sensitivity [00|01]<br>
      Set the TCM radio sensitivity: low = 00, high = 01</li>
    <li>sleep<br>
      Enter the energy saving mode</li>
    <li>wake<br>
      Wakes up from sleep mode</li>
    <br><br>
    For details see the TCM 120 User Manual available from <a href="http://www.enocean.com">www.enocean.com</a>.
  <br><br>
  </ul>
  <ul><b>TCM 310</b><br>
    <li>baseID [FF800000 ... FFFFFF80]<br>
      Set the BaseID.<br>
      Note: The firmware executes this command only up to then times to prevent misuse.</li>
    <li>bist<br>
      Perform Flash BIST operation (Built-in-self-test).</li>
    <li>maturity [00|01]<br>
      Waiting till end of maturity time before received radio telegrams will transmit:
      radio telegrams are send immediately = 00, after the maturity time is elapsed = 01</li>
    <li>pairForSec &lt;t/s&gt;<br>
      Set Fhem in teach-in mode.<br>
      The command is only required to teach-in bidirectional actuators
      e. g. EEP 4BS, RORG A5-20-01 (Battery Powered Actuator),
      see <a href="#pairForSec"> Bidirectional Teach-In / Teach-Out</a>.</li>
    <li>reset<br>
      Reset the device</li>
    <li>repeater [0000|0101|0102]<br>
      Set Repeater Level: off = 0000, 1 = 0101, 2 = 0102.</li>
    <li>sleep &lt;t/10 ms&gt; (Range: 00000000 ... 00FFFFFF)<br>
      Enter the energy saving mode</li>
    <li>subtel [00|01]<br>
      Transmitting additional subtelegram info: Enable = 01, Disable = 00</li>
    <br><br>
    For details see the EnOcean Serial Protocol 3 (ESP3) available from
    <a href="http://www.enocean.com">www.enocean.com</a>.
<br><br>
  </ul>

  <a name="TCMget"></a>
  <b>Get</b><br>
  <ul><b>TCM 120</b><br>
    <li>idbase<br>
      Get the BaseID. You need this command in order to control EnOcean devices,
      see the <a href="#EnOceandefine">EnOcean</a> paragraph.
      </li>
    <li>modem_status<br>
      Requests the current modem status.</li>
    <li>sensitivity<br>
      Get the TCM radio sensitivity, low = 00, high = 01</li>
    <li>sw_ver<br>
      Read the device SW version / HW version, chip-ID, etc.</li>
    <br><br>
    For details see the TCM 120 User Manual available from <a href="http://www.enocean.com">www.enocean.com</a>.
    <br><br>
  </ul>
  <ul><b>TCM 310</b><br>
    <li>baseID<br>
      Get the BaseID. You need this command in order to control EnOcean devices,
      see the <a href="#EnOceandefine">EnOcean</a> paragraph.</li>
    <li>numSecureDev<br>
      Read number of teached in secure devices.</li>
    <li>repeater<br>
      Read Repeater Level: off = 0000, 1 = 0101, 2 = 0102.</li>
    <li>version<br>
      Read the device SW version / HW version, chip-ID, etc.</li>
    <br><br>
    For details see the EnOcean Serial Protocol 3 (ESP3) available from
    <a href="http://www.enocean.com">www.enocean.com</a>.
    <br><br>
  </ul>

  <a name="TCMattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a name="blockSenderID">blockSenderID</a> &lt;own|no&gt;,
      [blockSenderID] = no is default.<br>
      Block receiving telegrams with a TCM SenderID sent by repeaters.      
      </li>
    <li><a href="#attrdummy">dummy</a></li>
    <li><a href="#do_not_notify">do_not_notify</a></li>
    <li><a href="#loglevel">loglevel</a></li>
  </ul>
  <br>
</ul>

=end html
=cut
