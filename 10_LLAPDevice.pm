package main;

use strict;
use warnings;
use SetExtensions;

sub LLAPDevice_Define($$);
sub LLAPDevice_Initialize($);
sub LLAPDevice_Parse($$);
sub LLAPDevice_Set($@);
sub LLAPDevice_SndRadio($$$);
sub LLAPDevice_TimerSet($);
sub LLAPDevice_Undef($$);

# LLAP personalities from CISECO
# TODO: Update with more, correct, codes						
my %personalities = (
	"U0000001-" => "DualRelay",
);

my %setcommands = (
	"deviceId" => {"cmd" => "CHDEVID", "format" => "^[A-Z-#@\?\\\*]{2}\$"},
	"startCyclicSleep" => {"cmd" => "CYCLE", "type" => "noArg"},
	"sendPing" => {"cmd" => "HELLO", "type" => "noArg"},
	"sleepInterval" => {"cmd" => "INTVL", "format" => "^\\d{1,3}[SMHD]\$"},
	"PANID" => {"cmd" => "PANID", "format" => "[0-9A-E][0-9A-F]{3}"},  # 0000 - EFFF (Default 5AA5)
	"Reboot" => {"cmd" => "REBOOT", "type" => "noArg"},
	"retries" => {"cmd" => "RETRIES", "format" => "^\\d\\d\$"},
	);

my %getcommands = (
	"LLAPVersion" => {"cmd" => "APVER", "ackFormat" => "^APVER[^-]+", "type" => "noArg"},
	"batteryLevel" => {"cmd" => "BATT", "ackFormat" => "^BATT[^-]+", "type" => "noArg"},
	"deviceName" => {"cmd" => "DEVNAME", "ackFormat" => "^[^-]+", "type" => "noArg"},
	"deviceType" => {"cmd" => "DEVTYPE", "ackFormat" => "^[^-]+", "type" => "noArg"},
	"firmwareVersion" => {"cmd" => "FVER", "ackFormat" => "^FVER[^-]+", "type" => "noArg"},
	"serialNumber" => {"cmd" => "SER", "ackFormat" => "^SER[^-]{6}", "type" => "noArg"},
	);

# Initialize
sub
LLAPDevice_Initialize($)
{
  my ($hash) = @_;

  $hash->{Match}     = "^LLAPDevice:";
  $hash->{DefFn}     = "LLAPDevice_Define";
  $hash->{UndefFn}   = "LLAPDevice_Undef";
  $hash->{ParseFn}   = "LLAPDevice_Parse";
  $hash->{SetFn}     = "LLAPDevice_Set";
  $hash->{GetFn}     = "LLAPDevice_Get";

  $hash->{AttrList}  = "IODev do_not_notify:1,0 ignore:0,1 dummy:0,1 " .
	  $readingFnAttributes;

  return undef;
}

# Define
sub
LLAPDevice_Define($$)
{
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def);
	my $name = $hash->{NAME};
	return "Illegal syntax: define <name> LLAPDevice <personality> <id>" 
		if(int(@a) != 4);
	return "Illegal device ID. ID should be two characters, A-Z and #@\?*" 
		if($a[3] !~ m/^[A-Z-#@\?\\\*]{2}/);
	return "Unknown device personality. Choose from " . join(", ", values(%personalities)) 
		unless(grep(/^$a[2]$/, values(%personalities)));
	if(exists($modules{LLAPDevice}{defptr}{$a[3]})) {
		my $msg = "LLAPDevice_Define: Device with ID $a[3] is already defined.";
		Log 1, $msg;
		return $msg;
	}
	$hash->{id} = $a[3];
	$hash->{personality} = $a[2];
	$modules{LLAPDevice}{defptr}{$a[3]} = $hash;
	$hash->{internals}{interfaces} = $interfaces{$a[2]};
	AssignIoPort($hash);

	if($hash->{personality} eq "DualRelay") {
		$getcommands{RelayA_Status} = {"cmd" => "RELAYA", "type" => "noArg", "ackFormat" => "RELAYA(ON|OFF)"};
		$getcommands{RelayB_Status} = {"cmd" => "RELAYB", "type" => "noArg", "ackFormat" => "RELAYA(ON|OFF)"};
		$setcommands{RelayA} = {"cmd" => "RELAYA", "format" => "^ON\$\|^OFF\$\|^TOG\$", "type" => "ON,OFF,TOG", "ackFormat" => "RELAYA(ON|OFF)"},
		$setcommands{RelayB} = {"cmd" => "RELAYB", "format" => "^ON\$\|^OFF\$\|^TOG\$", "type" => "ON,OFF,TOG", "ackFormat" => "RELAYB(ON|OFF)"},
	}  

	return undef;
}

# Set
sub
LLAPDevice_Set($@)
{
	my ($hash, @a) = @_;
	return "no set value provided" if(@a < 2);

	my $name = $hash->{NAME};
	my $dest = $hash->{id};
	my $cmd = $a[1];
	my $val = $a[2];
	
	if($cmd ne "?" && exists($setcommands{$cmd})) {
		if($val !~ m/$setcommands{$cmd}{"format"}/) {
			return "Illegal value $val for command $cmd";
		} else {
			$hash->{LastCommand} = $setcommands{$cmd}{"cmd"};
			if(defined $setcommands{$cmd}{"ackFormat"}) {
				IOWrite($hash, $hash->{id}, $setcommands{$cmd}{"cmd"}, $val, $setcommands{$cmd}{"ackFormat"});
			} else {
				return IOWrite($hash, $hash->{id}, $setcommands{$cmd}{"cmd"}, $val, $setcommands{$cmd}{"cmd"} . $val);
			}
		}
	} else {
		# No or unknown command given.
		# Return list of possible set commands to populate the UI
		my $setters;
		foreach my $tcmd (sort keys %setcommands) {
			if(exists($setcommands{$tcmd}{"type"})) {
				$setters .= $tcmd . ":" . $setcommands{$tcmd}{"type"} . " ";
			} else {
				$setters .= $tcmd . " ";
			}
		}
		return $setters;
	}
}

# Get
sub
LLAPDevice_Get($@)
{
	my ($hash, @a) = @_;
	return "No get command provided" if(@a < 2);

	my $name = $hash->{NAME};
	my $dest = $hash->{id};
	my $cmd = $a[1];
	my $val = $a[2];

	if(exists($getcommands{$cmd})) {
		$hash->{LastCommand} = $getcommands{$cmd}{"cmd"};
		return IOWrite($hash, $hash->{id}, $getcommands{$cmd}{"cmd"}, undef, $getcommands{$cmd}{"ackFormat"});
	} else {
		# Output list of available commands to populate the UI.
		my $getters = "Unknown argument $cmd, choose one of ";
		foreach my $tcmd (sort keys %getcommands) {
			if(exists($getcommands{$tcmd}{"type"})) {
				$getters .= $tcmd . ":" . $getcommands{$tcmd}{"type"} . " ";
			} else {
				$getters .= $tcmd . " ";
			}
		}
		return $getters;
	}
	return undef
}



# Parse
sub
LLAPDevice_Parse($$)
{
	my ($iohash, $msg) = @_;
	my (undef, $id, $command) = split(":", $msg);
	my $hash = $modules{LLAPDevice}{defptr}{$id};
	if(!$hash) {
		Log3 undef, 3, "LLAPDevice received message for unknown device '$id'.";
		return "UNDEFINED LLAPDevice $id";
	}
	my $name = $hash->{NAME};

	readingsBeginUpdate($hash);
	
	# Generic LLAP commands
	if($command eq "STARTED--") {
		if($hash->{personality} eq "DualRelay") {
			# Relays are always off when the device starts up
			$hash->{RelayA} = 0;
			$hash->{RelayB} = 0;
		}
	} elsif($command =~ m/^CHDEVID([A-Z-#@\?\\\*]{2})$/) {
		# Change device ID
		# TODO: Change definition in file or change will be lost.
		if(exists($modules{LLAPDevice}{defptr}{$1})) {
			Log 1, "LLAPDevice_Parse: Unable to change ID. Device with ID $1 is already defined.";
		} else {
			Log 1, "LLAPDevice_Parse: Changing device id from $hash->{id} to $1";
			return IOWrite($hash, $hash->{id}, "REBOOT---", "", "REBOOT---");			
#			$hash->{id} = $1;
		}
	} elsif($command =~ m/^SER(.*)$/) {
		# LLAP version
		readingsBulkUpdate($hash, "SerialNumber", $1);
		Log3 $name, 5, "LLAPDevice $name received reading: SerialNumber = $1";
	} elsif($command =~ m/^APVER([\d\.]+)$/) {
		# LLAP version
		readingsBulkUpdate($hash, "LLAPVersion", $1);
		Log3 $name, 5, "LLAPDevice $name received reading: LLAP version = $1";
	} elsif($command =~ m/^BATT(\d\.\d\d)$/) {
		# Battery level
		readingsBulkUpdate($hash, "batteryLevel", $1);
		Log3 $name, 5, "LLAPDevice $name received reading: Battery level = $1";
	} elsif($command eq "HELLO") {
		# Ok, device is alive.
	} elsif($command eq "REBOOT") {
		# Ok, device is going to reboot. Not much to do about that.
	}
	
	# Dual Relay
	elsif($command eq "RELAYAON") {
		readingsBulkUpdate($hash, "RelayA", 1);
		$hash->{RelayA} = 1;
	} elsif($command eq "RELAYAOFF") {
		readingsBulkUpdate($hash, "RelayA", 0);
		$hash->{RelayA} = 0;
	} elsif($command eq "RELAYBON") {
		readingsBulkUpdate($hash, "RelayB", 1);
		$hash->{RelayB} = 1;
	} elsif($command eq "RELAYBOFF") {
		readingsBulkUpdate($hash, "RelayB", 0);
		$hash->{RelayB} = 0;
	
	} elsif($hash->{LastCommand} eq "DEVNAME") {	
		readingsBulkUpdate($hash, "DeviceName", $command);
	}

	else {
	# Unknown command
		Log3 $name, 5, "LLAPDevice $name received unknown command: $command";
	}

	# Update state
	if($hash->{personality} eq "DualRelay") {
		my $state = "";
		if(defined $hash->{RelayA}) {
			$state .= "OFF" if($hash->{RelayA} == 0);
			$state .= "ON" if($hash->{RelayA} == 1);
		} else {
			$state .= "?";
		}
		$state .= " | ";
		if(defined $hash->{RelayB}) {
			$state .= "OFF" if($hash->{RelayB} == 0);
			$state .= "ON" if($hash->{RelayB} == 1);
		} else {
			$state .= "?";
		}
		readingsBulkUpdate($hash, "state", $state);
	}
	readingsEndUpdate($hash, 1);
	return $hash->{NAME};
}
	   

# send LLAPDevice Radio
sub
LLAPDevice_SndRadio($$$)
{
#  my ($hash, $dest, $msg) = @_;
#  IOWrite($hash, $dest, $msg);
#  Log3 $hash->{NAME}, 4, "LLAPDevice IOWrite $hash->{NAME} $dest $msg";
}

# LLAPDevice_Set called from sub InternalTimer()
sub
LLAPDevice_TimerSet($)
{
  my ($par)=@_;
  LLAPDevice_Set($par->{hash}, @{$par->{timerCmd}});
}

# Undef
sub
LLAPDevice_Undef($$)
{
  my ($hash, $arg) = @_;
  delete $modules{LLAPDevice}{defptr}{uc($hash->{DEF})};
  return undef;
}

1;

=pod
=begin html

<a name="LLAPDevice"></a>
<h3>LLAPDevice</h3>

=end html
=cut
