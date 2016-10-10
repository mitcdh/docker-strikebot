#!/usr/bin/perl -w

use strict;
use warnings;
use Storable;

use POE qw(Component::IRC::State Component::IRC::Plugin::Connector Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::BotAddressed Component::IRC::Plugin::BotTraffic Component::IRC::Plugin::CTCP Component::IRC::Plugin::NickReclaim Component::IRC::Plugin::NickServID Component::IRC::Plugin::BotCommand);
use POE::Component::IRC::Common qw( :ALL );

# Used by the bot
my ($nickname, $username, $ircname) = $ENV{'NICK'};
my $server = $ENV{'SERVER'}; ;
my $nickservpw = $ENV{'NS_PASS'};
my @ownerchannels = split(',', $ENV{'OWNER_CHANNELS'});
my @channels = split(',', $ENV{'CHANNELS'});

#my @channels = ( '#bots' );

# Datafiles
my $mapfile = 'mapdata.dat';

# Populated from mapfile
my @suburbs;
my @places;

my %targets;
my %feeding;
my %dragging;
my %emptytargetmsg;
my %noping;
my %targettime;

#Initalisation of map
&fill_map();

my $irc = POE::Component::IRC::State->spawn (
	nick => $nickname,
	ircname => $ircname,
	username => $username,
	server => $server,
	flood => 1,	# Allow flooding.
) or die "Ooops $!";

POE::Session ->create (
	package_states => [
		main => [ qw(_default _start irc_001 irc_353 irc_msg irc_notice irc_invite irc_public irc_bot_addressed irc_bot_mentioned irc_bot_mentioned_action irc_bot_public irc_bot_msg) ],
	],
	heap => {irc => $irc },
);

$poe_kernel->run();
exit;

sub _start 
{
	my ($kernel, $heap) = @_[KERNEL ,HEAP];

	# retrieve our component's object from the heap where we stashed it
	my $irc = $heap->{irc};

	# Initialise plugins
	$irc->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
	$irc->plugin_add( 'NickReclaim' => POE::Component::IRC::Plugin::NickReclaim->new() );
	$irc->plugin_add( 'NickServID', POE::Component::IRC::Plugin::NickServID->new(
		Password => $nickservpw
	));
	$irc->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( 
		RejoinOnKick => 1,
		Retry_when_banned => 300,
	));
	$irc->plugin_add( 'BotAddressed', POE::Component::IRC::Plugin::BotAddressed->new() );
	$irc->plugin_add( 'BotTraffic', POE::Component::IRC::Plugin::BotTraffic->new() );
	$irc->plugin_add( 'CTCP' => POE::Component::IRC::Plugin::CTCP->new(
		version => $ircname,
		userinfo => $ircname,
	));
	
	# Register for events and connect to server
	$irc->yield( register => 'all' );
	#$irc->yield( register => qw(irc_001 irc_353 irc_notice irc_msg irc_public irc_bot_addressed irc_bot_mentioned irc_bot_mentioned_action irc_bot_public irc_bot_msg) );
	$irc->yield( connect => { } );
	return;
}

# We registered for all events, this will produce some debug info.
 sub _default 
{
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ( "$event: " );

	if ($event =~ /_child|irc_(00\d|2(5[1-5]|6[56])|33[23]|366|37[256]|ctcp.*|isupport|join|kick|mode|nick|part|ping|topic|quit)/) {
		# Do not log these events
	}
	else {
		for my $arg (@$args) {
			if ( ref $arg eq 'ARRAY' ) {
			   push( @output, '[' . join(' ,', @$arg ) . ']' );
			}
			else {
			   push ( @output, "'$arg'" );
			}
		}
		print join ' ', @output, "\n";
	}
	return 0;	# Don't handle signals.
}

# Fires once we're fully connected
sub irc_001 
{	
	my $sender = $_[SENDER];

	# Since this is an irc_* event, we can get the component's object by
	# accessing the heap of the sender. Then we register and connect to the
	# specified server.
	my $irc = $sender->get_heap();

	print "Connected to ", $irc->server_name(), "\n";
	
	# set mode +B = identify as bot
	$irc->yield( mode => "$nickname +B" );

	# we join our channels
	$irc->yield( join => $_ ) for @channels;

	return;
}

# Nick list
sub irc_353 
{
	my ($heap,$args) = @_[HEAP,ARG2];
	my $channel = lc $args->[1];
	my $nicklist = $args->[2];
	push @{ $heap->{NAMES}->{ $channel } }, ( split /\s+/, $nicklist );
	my $nickname = $irc->nick_name();
	$nicklist =~ s/$nickname //;
	print "In $channel with $nicklist \n";
}

sub irc_public 
{
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG3];
	my $nick = ( split /!/, $who )[0];
	my $channel = lc $where->[0];
	my $admintest = ($irc->is_channel_admin( $channel, $nick ) || $irc->is_channel_owner( $channel, $nick )) ? 1 : 0;
	my $optest = ($irc->is_channel_operator( $channel, $nick ) || $admintest) ? 1 : 0;
	$what = strip_color(strip_formatting($what));
	
	if(grep { $_ eq $channel } @ownerchannels)
	{
		if ($what =~ /^!t(arget)*s*$/i)
		{
			foreach my $key (sort keys %targets) 
			{
				$irc->yield (privmsg => $channel => "\002$key:\002 " . &get_target($key));
			}
		}
	}
	else
	{
		if ($what =~ /^!t(arget)*s*$/i)
		{
			if ($optest)
			{
				$irc->yield (privmsg => $channel => "\002TARGET(S):\002 " . &get_target($channel));
			}
			else
			{
				$irc->yield (notice => $nick => "\002TARGET(S):\002 " . &get_target($channel));
			}
		}
		elsif ($what =~ /^!strike$/i && $optest)
		{
			if ($admintest || !$noping{$channel})
			{
				$irc->yield (names => "$channel");
				my $nicklist = join(' ', $irc->channel_list($channel));
				$irc->yield (privmsg => $channel => "\002STRIKE TIME!\002 " . $nicklist);
				$irc->yield (notice => $channel => "\002TARGET(S):\002 " . &get_target($channel));
			}
			else
			{
				$irc->yield (notice => $nick => "Strike Ping (!strike) Restricted in This Channel");
			}
		}
		elsif ($what =~ /^!settarget (.+)$/i && $optest)
		{	
			$irc->yield (notice => $nick => &set_target($1,$channel));
		}
		elsif ($what =~ /^!setorders (.+)$/i && $optest)
		{
			$targets{$channel} = "$1";
			$irc->yield (notice => $nick => 'Orders Set');
		}
		elsif ($what =~ /^!removetarget$/i && $optest)
		{
			$targets{$channel} = "";
			$feeding{$channel} = "";
			$dragging{$channel} = "";
			$irc->yield (notice => $nick => 'Target Removed');
		}
		elsif (($what =~ /^!setfeeding (off|on)$/i || $what =~ /^!setdragging (off|on)$/i) && $optest)
		{
			$irc->yield (notice => $nick => &set_flags($what,$channel));
		}
		elsif ($what =~ /^!setemptytargetmsg (.+)$/i && $admintest)
		{
			$emptytargetmsg{$channel} = "$1";
			$irc->yield (notice => $nick => 'Empty Target Mesage Set');
		}
		elsif ($what =~ /^!removeemptytargetmsg$/i && $admintest)
		{
			$emptytargetmsg{$channel} = "";
			$irc->yield (notice => $nick => 'Empty Target Mesage Removed');
		}
		elsif ($what =~ /^!setping (off|on)$/i && $admintest)
		{
			if($1 eq "off")
			{
				$noping{$channel} = 1;
				$irc->yield (notice => $nick => "Strike Ping (!strike) Restricted For Channel '$channel'");
			}
			else
			{
				$noping{$channel} = 0;
				$irc->yield (notice => $nick => "Strike Ping (!strike) Unrestricted For Channel '$channel'");
			}
		}
	}	
}

sub irc_msg 
{
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
	my $nick = ( split /!/, $who )[0];
	$what = strip_color(strip_formatting($what));
	
	print "NOTICE: <$who> $what\n";
	
	if ($what =~ /^!t(arget)*s*/i)
	{
		$irc->yield (privmsg => $nick => &target_lookup(&trim($what)));
	}
}

sub irc_notice
{
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
	my $nick = ( split /!/, $who )[0];
	$what = strip_color(strip_formatting($what));
	
	print "NOTICE: <$who> $what\n";
	
	if ($what =~ /^!t(arget)*s*/i)
	{
		$irc->yield (notice => $nick => &target_lookup(&trim($what)));
	}
}

sub irc_bot_addressed 
{
	my ($kernel, $heap) = @_[KERNEL, HEAP];
	my $nick = ( split /!/, $_[ARG0] )[0];
	my $channel = lc $_[ARG1]->[0];
	my $what = $_[ARG2];

	print "Addressed: $channel: <$nick> $what\n";
}

sub irc_invite
{
     my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
     my $nick = ( split /!/, $who )[0];

     print "I was invited to $where\n";
	$irc->yield( join => $where );
}	

sub irc_bot_mentioned 
{
	my ($nick) = ( split /!/, $_[ARG0] )[0];
	my ($channel) = lc $_[ARG1]->[0];
	my ($what) = $_[ARG2];

     print "$channel: <$nick> $what\n";
}

sub irc_bot_mentioned_action 
{
	my ($nick) = ( split /!/, $_[ARG0] )[0];
	my ($channel) = lc $_[ARG1]->[0];
	my ($what) = $_[ARG2];

     print "$channel: * $nick $what\n";
}

sub irc_bot_public 
{
     my ($kernel, $heap) = @_[KERNEL, HEAP];
     my $channel = lc $_[ARG0]->[0];
     my $what = $_[ARG1];

     print strip_color(strip_formatting("$channel: <$nickname> $what\n"));
     return;
}

sub irc_bot_msg 
{
     my ($kernel, $heap) = @_[KERNEL, HEAP];
     my $nick = $_[ARG0]->[0];
     my $what = $_[ARG1];

     print strip_color(strip_formatting("I said '$what' to user $nick\n"));
     return;
}

sub get_target
{
	my $channel = $_[0];
	
	if($targets{$channel})
	{
		my $feedingout = "";
		my $draggingout = "";
		if($feeding{$channel}) 
		{
			$feedingout = " \002FEEDING!\002";
		}
		if($dragging{$channel}) 
		{
			$draggingout = " \002DRAGGING!\002";
		}
		return "$targets{$channel}$draggingout$feedingout";
	}
	else
	{
		if($emptytargetmsg{$channel})
		{
			return $emptytargetmsg{$channel};
		}
		else
		{
			return "\002[No Target Set]\002";
		}
	}
}

sub set_flags
{
	my $what = $_[0];
	my $channel = $_[1];
		
	if ($what =~ /^\!setfeeding /i)
	{
		$what =~ s/^\!setfeeding //i;
		
		if ($what =~ /on/i)
		{
			$feeding{$channel} = "1";
			return 'Feeding Flag Set';
		}
		if ($what =~ /off/i)
		{
			$feeding{$channel} = "";
			return 'Feeding Flag Removed';
		}
	}
	
	elsif ($what =~ /^\!setdragging /i)
	{
		$what =~ s/^\!setdragging //i;
		
		if ($what =~ /on/i)
		{
			$dragging{$channel} = "1";
			return 'Dragging Flag Set';
		}
		if ($what =~ /off/i)
		{
			$dragging{$channel} = "";
			return 'Dragging Flag Removed';
		}
	}
}

sub set_target 
{
	my $where = $_[0];
	my $channel = $_[1];
	
	if($where =~ /(\d{1,2})[,\-](\d{1,2})/)
	{
		$targets{$channel} = &find_location($where);
		if ($where =~ /f/i)
		{
			$feeding{$channel} = "1";
		}
		if ($where =~ /d/)
		{
			$dragging{$channel} = "1";
		}
		return 'Target List Filled & Set';
	}
	else
	{
		return 'ERROR: Invalid Coords Format';
	}
}

sub target_lookup 
{
	my $what = $_[0];
	
	if($what =~ /(\d{1,2})[,\-](\d{1,2})/)
	{	
		return find_location($what);
	}
	else
	{
		return 'When followed by coords in XX,YY format returns target information for up to five targets e.g. !target xx,yy xx,yy';
	}
}

sub find_location 
{
	my $coords = $_[0];
	my $endlist;
	my $list_size = 0;
		
	while ($coords =~ /(\d{1,2})[,\-](\d{1,2})/g)
	{
		$list_size++;
	}
	if(1 == $list_size)
	{
		$coords =~ /(\d{1,2})[,\-](\d{1,2})/;
		$endlist = &get_place($1, $2) . " [$1, $2] in " . &get_suburb($1, $2) . "! http://dssrzs.org/map/location/$1\-$2";
	}
	else
	{
		my @targetlist = ();
		while ($coords =~ /(\d{1,2})[,\-](\d{1,2})/g && scalar(@targetlist) < 5)
		{
			if(scalar(@targetlist) == 0)
			{
				push(@targetlist, &get_place($1, $2) . " [$1, $2] http://dssrzs.org/map/location/$1\-$2");
			}
			else
			{
				push(@targetlist, &get_place($1, $2) . " [$1, $2]");
			}
		}
		$endlist = "Primary: " . $targetlist[0] . " Secondary: " . $targetlist[1];
		if (3 <= $list_size)
		{
			$endlist = $endlist . " Tertiary: " . $targetlist[2];
			if (4 <= $list_size)
			{
				$endlist = $endlist . " Quaternary: " . $targetlist[3];
				if (5 <= $list_size)
				{
					$endlist = $endlist . " Pentenary: " . $targetlist[4];
				}
			}
		}
	}		
	return "$endlist";
}

sub get_place 
{
	return $places[int($_[0])][int($_[1])];
}

sub get_suburb 
{
	return $suburbs[int($_[1] / 10)][int($_[0] / 10)];
}

sub is_suburb
{
	my $el = $_[0];
	for(my $i = 0; $i < 10; $i++) { for(my $k = 0; $k < 10; $k++) { return 1 if($suburbs[$i][$k] eq $el); } }
	return 0;
}

sub fill_map 
{
	print "Filling map...";
	open MAPDATA, $mapfile or die "FAILED - $!\n";
	chomp(my @lines = <MAPDATA>);
	close MAPDATA;	
	my $line;
	for(my $i = 0; $i < 10; $i++) { for(my $k = 0; $k < 10; $k++) { $suburbs[$i][$k] = $lines[$line++]; } }
	for(my $i = 0; $i < 100; $i++) { for(my $k = 0; $k < 100; $k++) { $places[$i][$k] = $lines[$line++]; } }
	print "DONE!\n";
}

sub trim
{
	my $what = $_[0];
	$what =~ s/^\!\w+ //i;
	return $what;
}
