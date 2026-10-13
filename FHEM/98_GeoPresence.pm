package main;

use strict;
use warnings;
no warnings 'redefine'; # FHEM reload evaluates this file again in package main.
use utf8;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(decode_base64);
use Encode qw(decode encode FB_CROAK);
use Time::Local qw(timegm timelocal);
use Time::HiRes ();
use POSIX ();
use IO::Socket::INET ();
use Errno qw(EAGAIN EWOULDBLOCK EINTR);

our (%defs, %attr, %data, %selectlist, $init_done, $readingFnAttributes, $unicodeEncoding);
our (%FW_webArgs, $FW_ME, $FW_subdir);

# Only controller devices own runtime state. Readings are ordinary FHEM snapshots,
# never an executable queue. Only qualified unfinished trips may resume.
my %GP_DEFAULT = (
    action_max_age => 90, future_tolerance => 30, reorder_window => 2,
    departure_grace => 60, minimum_away => 60, phone_absence_window => 180,
    phone_poll => 5, motion_max_age => 180, approach_timeout => 600,
    zone_display_max_age => 43200, actor_timeout => 60, departure_margin => 200,
    trip_resume_max_age => 172800,
    arrival_wait_walking => 60, arrival_wait_running => 30, arrival_wait_cycling => 20,
    arrival_wait_automotive => 10, arrival_wait_unknown => 60, arrival_motion_max_age => 30,
);
my %GP_ATTRS = (
    controller => [qw(webhookPath webhookPort webhookBindAddress webhookAllowedPeers logFile debugLog), sort keys %GP_DEFAULT],
    resident => [qw(sourceMode deviceId webhookUser
        phoneProxies phoneSignalMode allowDoor allowGarage)],
    location => [qw(zoneId label groups)],
    action => [qw(target command contact feedbackDevice positionSignalMode stateDevice upperContact
        lowerContact message priority channel)],
    rule => [qw(enabled trigger residents locations locationGroup afterExit arrivalFilter action cooldown)],
);
my %GP_ALLOWED = map { $_ => 1 } map { @$_ } values %GP_ATTRS;
my %GP_ENUMS = (
    debugLog => [qw(auto 0 1)], sourceMode => [qw(geofency_phone geofency_only phone_only)],
    phoneSignalMode => [qw(state measurement)], positionSignalMode => [qw(state measurement)], enabled => [qw(1 0)],
    allowDoor => [qw(0 1)], allowGarage => [qw(0 1)],
    trigger => [qw(arrival enter exit)],
    arrivalFilter => [qw(any vehicle)],
    channel => [qw(0 1 2 10)], priority => [qw(0 1 2)],
);
my %GP_ACTION_ATTRS = (
    door_open => [qw(target command contact feedbackDevice positionSignalMode)],
    garage_open => [qw(target command stateDevice upperContact lowerContact positionSignalMode)],
    notify => [qw(message priority channel)],
    switch_on => [qw(target command)],
);
my $GP_JSON = JSON::PP->new->canonical->utf8;
my $GP_CHECKPOINT_JSON = JSON::PP->new->canonical->ascii;
my %GP_AUTH;

sub GP_UsesSource {
    my ($mode,$source)=@_;
    $mode //= 'geofency_phone';
    return ($source eq 'phone' ? $mode =~ /\A(?:geofency_phone|phone_only)\z/
        : $mode =~ /\A(?:geofency_phone|geofency_only)\z/) ? 1:0;
}

sub GP_ResidentAttrEnabled {
    my ($mode,$key)=@_;
    return GP_UsesSource($mode,'phone') if $key =~ /\A(?:phoneProxies|phoneSignalMode)\z/;
    return GP_UsesSource($mode,'geo') if $key =~ /\A(?:deviceId|webhookUser|allowDoor|allowGarage)\z/;
    return 1;
}

sub GP_RuleAttrEnabled {
    my ($name,$key)=@_;
    my $trigger=GP_Attr($name,'trigger','');
    return 1 unless $trigger =~ /\A(?:arrival|enter|exit)\z/;
    return $trigger eq 'arrival' if $key eq 'arrivalFilter';
    return $trigger ne 'arrival' && !length GP_Attr($name,'locationGroup','') if $key eq 'locations';
    return $trigger ne 'arrival' && !length GP_Attr($name,'locations','') if $key eq 'locationGroup';
    return 1;
}

# These lists describe the normal FHEMWEB widgets; they never write attributes,
# publish events or change runtime permissions. Keep enum validation in sync.
sub GP_AttrSpec {
    my ($key)=@_;
    return $GP_ENUMS{$key} ? $key.':'.join(',',@{$GP_ENUMS{$key}}) : $key;
}

sub GP_UpdateAttrLists {
    my ($only)=@_;
    my (@devices,@proxies,%choices,%groups);
    my %references=(action=>'action',residents=>'resident',locations=>'location');
    for my $name (sort keys %defs) {
        my $d=$defs{$name};
        # FHEM sensor names may start with digits, unlike GeoPresence defines.
        # Exclude widget separators and HTML metacharacters from choices.
        next unless $name =~ /\A[A-Za-z0-9_.-]+\z/;
        push @proxies,$name if ($d->{TYPE}//'') eq 'PRESENCE';
        next unless ($d->{TYPE}//'') eq 'GeoPresence' && $GP_ATTRS{$d->{SUBTYPE}//''};
        push @devices,$d;
        push @{$choices{$d->{CONTROLLER}//''}{$d->{SUBTYPE}}},$name;
        if (($d->{SUBTYPE}//'') eq 'location') {
            $groups{$d->{CONTROLLER}//''}{$_}=1 for GP_List(GP_Attr($name,'groups',''));
        }
    }
    for my $d ($only ? ($only) : @devices) {
        my $kind=$d->{SUBTYPE};
        # During config loading accept old, unused action attributes as before.
        # INITIALIZED narrows the offered list; existing values remain deletable.
        my $keys=$kind eq 'action' && $init_done
            ? $GP_ACTION_ATTRS{$d->{ACTIONTYPE}} : $GP_ATTRS{$kind};
        my @spec;
        for my $key (@$keys) {
            next if $kind eq 'resident' && $init_done
                && !GP_ResidentAttrEnabled(GP_Attr($d->{NAME},'sourceMode','geofency_phone'),$key);
            next if $kind eq 'rule' && $init_done && !GP_RuleAttrEnabled($d->{NAME},$key);
            my $entry=GP_AttrSpec($key);
            if ($key eq 'command' && ($d->{ACTIONTYPE}//'') ne 'notify') {
                $entry='command:select,'.($d->{ACTIONTYPE} eq 'door_open' ? 'lock#unlocked':'on');
            }
            if (exists($references{$key}) || $key eq 'phoneProxies') {
                my @names=$key eq 'phoneProxies' ? @proxies
                    : @{$choices{$d->{CONTROLLER}//''}{$references{$key}}//[]};
                # Preserve visible stale references so opening an editor cannot
                # silently discard them; validate still reports missing devices.
                my %names=map {$_=>1} (@names,grep {/\A[A-Za-z0-9_.-]+\z/} GP_List(GP_Attr($d->{NAME},$key,'')));
                @names=sort keys %names;
                $entry=$key.($key eq 'action' ? ':select,,':':multiple-strict,').join(',',@names) if @names;
            }
            if ($key eq 'locationGroup' || $key eq 'afterExit') {
                my @tags=sort keys %{$groups{$d->{CONTROLLER}//''}//{}};
                my @names=$key eq 'locationGroup' ? @tags : ((map {'group:'.$_} @tags),
                    map {'location:'.$_} @{$choices{$d->{CONTROLLER}//''}{location}//[]});
                push @names,GP_Attr($d->{NAME},$key,'') if length GP_Attr($d->{NAME},$key,'');
                my %seen; @names=grep {!$seen{$_}++} @names;
                $entry=$key.':select,,'.join(',',@names) if @names;
            }
            push @spec,$entry;
        }
        $d->{'.AttrList'}=join(' ',@spec,($readingFnAttributes//''));
    }
}

sub GP_Auth {
    my ($resident)=@_;
    $GP_AUTH{$resident}//=[getKeyValue('GeoPresence_'.$resident.'_auth')];
    return @{$GP_AUTH{$resident}};
}

sub GeoPresence_Initialize {
    my ($hash) = @_;
    $hash->{DefFn} = 'GeoPresence_Define';
    $hash->{UndefFn} = 'GeoPresence_Undef';
    $hash->{DeleteFn} = 'GeoPresence_Delete';
    $hash->{SetFn} = 'GeoPresence_Set';
    $hash->{GetFn} = 'GeoPresence_Get';
    $hash->{AttrFn} = 'GeoPresence_Attr';
    $hash->{NotifyFn} = 'GeoPresence_Notify';
    $hash->{AttrList} = join(' ', map {GP_AttrSpec($_)} sort keys %GP_ALLOWED)
        . ' ' . ($readingFnAttributes // '');
    GP_UpdateAttrLists();
    # FHEM calls Initialize on reload; old callbacks may still be queued.
    for my $d (values %defs) {
        next unless ($d->{TYPE} // '') eq 'GeoPresence' && ($d->{SUBTYPE} // '') eq 'controller';
        GP_ResetController($d,'resume');
    }
}

sub GP_Now { return Time::HiRes::time(); }
sub GP_Mono { return Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); }

sub GP_CPU { my ($user,$system)=times; return $user+$system; }

# Passive timing within a timer invocation only. Nested spans have exclusive
# self time, so a slow FHEM callback is not also charged to all its callers.
# Preserve the caller's context and exception; no commands or events are added.
sub GP_Profile {
    my ($c,$phase,$target,$code)=@_;
    my $work=$c->{helper}{gp_work};
    return $code->() unless $work;
    my $parent=$work->{frame};
    my $frame={children=>0};
    my $start=GP_Mono();
    my ($result,@result,$ok,$error);
    my $context=wantarray;
    {
        local $work->{frame}=$frame;
        local $@;
        $ok=eval {
            if (!defined $context) { $code->(); }
            elsif ($context) { @result=$code->(); }
            else { $result=$code->(); }
            1;
        };
        $error=$@ unless $ok;
    }
    my $elapsed=GP_Mono()-$start; $elapsed=0 if $elapsed<0;
    $parent->{children}+=$elapsed if $parent;
    my $self=$elapsed-$frame->{children}; $self=0 if $self<0;
    my $row=$work->{phases}{join('|',$phase,$target)}//={phase=>$phase,target=>$target,calls=>0,elapsed_ms=>0,self_ms=>0};
    $row->{calls}++; $row->{elapsed_ms}+=$elapsed*1000; $row->{self_ms}+=$self*1000;
    die $error unless $ok;
    return $context ? @result : $result;
}
sub GP_Attr { return ($attr{$_[0]} // {})->{$_[1]} // $_[2]; }
sub GP_List { return grep { length } split /,/, ($_[0] // ''); }
sub GP_Name { return defined($_[0]) && $_[0] =~ /\A[A-Za-z][A-Za-z0-9_.-]*\z/; }
sub GP_Group { return GP_Name($_[0]) && length($_[0])<=64; }
sub GP_Id { return defined($_[0]) && $_[0] =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/; }
sub GP_Number { return defined($_[0]) && $_[0] =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/; }
sub GP_IPv4 {
    my ($address)=@_;
    return 0 unless defined($address) && $address =~ /\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z/;
    my @octets=split /\./,$address;
    return $octets[0]>0 && $octets[0]<224 && !grep {$_>255} @octets;
}
sub GP_PeerListValid {
    my ($value)=@_;
    return 0 unless defined($value) && length($value);
    my @peers=split /,/,$value,-1;my %seen;
    return @peers<=16 && !grep {!GP_IPv4($_) || $seen{$_}++} @peers;
}
sub GP_Field { return ($defs{$_[0] // ''} // {})->{$_[1]} // $_[2]; }
sub GP_IsOpening { return ($_[0]//'') =~ /\A(?:door_open|garage_open)\z/; }

sub GP_LogPathValid {
    my ($path)=@_;
    return defined($path) && length($path)<=512 && $path =~ m{\A[A-Za-z0-9_./%+-]+\.(?:log|txt)\z}
        && $path !~ /%(?![YmdHM])/;
}

sub GP_LogPath {
    my ($c)=@_;
    my $pattern=GP_Attr($c->{NAME},'logFile','');
    return '' unless GP_LogPathValid($pattern);
    return POSIX::strftime($pattern,localtime(GP_Now()));
}

# Logging is an output adapter, never a Reading update or FHEM event. The
# operating mode controls actions; debugLog independently controls diagnostics.
sub GP_DebugLogEnabled {
    my ($c,$detail)=@_;
    return 0 unless $c;
    my $setting=GP_Attr($c->{NAME},'debugLog','auto');
    return $setting eq '1' ? 1:0 unless $setting eq 'auto';
    $detail//={};
    my $mode=$detail->{mode}//(defined($detail->{resident}) ? GP_EffectiveMode($c,$detail->{resident},0)
        : GP_Mode($c->{NAME}));
    return $mode eq 'debug' || $mode eq 'learning' ? 1:0;
}

sub GP_LogText {
    my ($text)=@_;
    $text//='';
    # FHEM's bytestream attributes contain UTF-8 bytes, while module literals
    # are characters. Decode before joining or removing Unicode controls.
    $text=decode('UTF-8',$text) if !$unicodeEncoding && !utf8::is_utf8($text);
    $text =~ s/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/ /g;
    return substr($text,0,512);
}

sub GP_LogResident {
    my ($r)=@_;
    my $rr=GP_Field($r,'ROOMMATE',$r);
    return GP_LogText(GP_Attr($r,'alias',GP_Attr($rr,'alias',$rr)));
}

# Only short, human-readable actions and operational warnings use FHEM's log.
sub GP_NormalLog {
    my ($c,$level,$text)=@_;
    return unless $c && defined &Log3;
    return if $level>GP_Attr($c->{NAME},'verbose',GP_Attr('global','verbose',3));
    my $line=$c->{NAME}.' GeoPresence: '.GP_LogText($text);
    GP_Profile($c,'normal_log',$c->{NAME},sub {Log3($c->{NAME},$level,$unicodeEncoding ? $line : encode('UTF-8',$line))});
}

sub GP_LogAction {
    my ($c,$r,$row)=@_;
    my $reason=$row->{reason}//'';
    my $who=GP_LogResident($r);
    my $target=GP_LogText(GP_Attr($row->{target}//'','alias',$row->{target}//''));
    my ($text,$level)=('',3);
    if ($reason eq 'zone observation processed' && $row->{changed}) {
        my $zone=GP_LogText($row->{zone_label}//$row->{zone});
        $text=($row->{entry} ? 'Entered area “' : 'Left area “').$zone.'”.';
    } elsif ($reason eq 'arrival confirmed' && $row->{changed} && ($row->{source}//'') eq 'phone_present') {
        $text='Arrived home (phone detected).';
    } elsif ($reason eq 'phone absence qualified' && $row->{changed}) {
        $text='Marked absent (phone absence confirmed).';
    } elsif ($reason eq 'notification dispatched' || $reason eq 'notification failed') {
        my %channels=(0=>'SmartHome',1=>'SmartHome',2=>'SmartAdmin',10=>'Pushover');
        my $channel=$channels{$row->{channel}//0}//'notification service';
        if ($reason eq 'notification dispatched') {
            $text='Notification handed to '.$channel.': “'.GP_LogText($row->{message}).'”.';
        } else { $text='Could not hand notification to '.$channel.'.'; $level=2; }
    } elsif ($reason eq 'switch command dispatched' || $reason eq 'switch command failed') {
        $text=($reason eq 'switch command dispatched' ? 'Switch-on requested for “' : 'Switch-on failed for “').$target.'”.';
        $level=2 if $reason eq 'switch command failed';
    } elsif ($reason eq 'actor command dispatched' || $reason eq 'actor command failed') {
        my $kind=($row->{kind}//'') eq 'door_open' ? 'Door opening' : 'Garage opening';
        $text=$reason eq 'actor command dispatched'
            ? $kind.' requested for “'.$target.'”.'
            : 'Could not request '.lcfirst($kind).' for “'.$target.'”.';
        $level=2 if $reason eq 'actor command failed';
    } elsif ($reason eq 'actor feedback') {
        my $door=($row->{kind}//'') eq 'door_open';
        if (($row->{result}//'') eq 'confirmed') {
            $text=$door ? 'Door opener “'.$target.'” confirmed the opening pulse.' : 'Garage “'.$target.'” is open.';
        } else {
            my %results=(failed=>'failed',cancelled=>'cancelled',uncertain=>'ended without confirmation');
            return unless exists $results{$row->{result}//''};
            $text=($door ? 'Door opening' : 'Garage opening').' for “'.$target.'” '.$results{$row->{result}}.'.';
            $level=2;
        }
    }
    GP_NormalLog($c,$level,$who.': '.$text) if length $text;
}

# Structured diagnostics go exclusively to logFile, independent of verbose.
# Only selected fields enter it, never headers, bodies or credentials.
sub GP_Log {
    my ($c,$level,$event,$detail)=@_;
    return unless $c;
    if ($event eq 'listener_error') {
        GP_NormalLog($c,2,'Could not start webhook listener; check listener configuration.');
    } elsif ($event eq 'configuration_invalid' || $event eq 'configuration_ready') {
        GP_NormalLog($c,$level,GP_LogResident($detail->{resident}).': '
            .($event eq 'configuration_invalid' ? 'Invalid configuration; processing suspended.' : 'Configuration valid again.'));
    } elsif ($event eq 'geometry_applied') {
        GP_NormalLog($c,$level,GP_LogResident($detail->{resident}).': Location geometry confirmed for production; trips reset.');
    }
    return unless GP_DebugLogEnabled($c,$detail);
    my $path=GP_LogPath($c);
    return unless length($path);
    my $rate=$c->{helper}{gp_log_rate}//={start=>GP_Mono(),count=>0};
    %$rate=(start=>GP_Mono(),count=>0) if GP_Mono()-$rate->{start}>=60 || GP_Mono()<$rate->{start};
    return if ++$rate->{count}>301;
    ($level,$event,$detail)=(2,'log_rate_limit',{reason=>'Further log entries suppressed for this minute'}) if $rate->{count}==301;
    my %safe;
    for my $key (qw(resident mode route isTest status reason field ignored_multiline phase rule kind target source zone observed received entry result changed motion motion_time wait_seconds deadline confirmation phone_state phone_health phone_latest home_exit departure_armed geometry_changes elapsed_ms cpu_ms start_lag_ms slowest_phase slowest_target slowest_self_ms started_at)) {
        next unless defined(($detail//{})->{$key}) && !ref($detail->{$key});
        $safe{$key}=substr($detail->{$key},0,512);
    }
    # ASCII JSON escapes embedded line breaks and Unicode separators as data.
    my $text=$c->{NAME}.' GeoPresence '.$event.' '.JSON::PP->new->canonical->ascii->encode(\%safe);
    my $error=GP_Profile($c,'diagnostic_file',$c->{NAME},sub {GP_WriteLog($path,$level,$text)});
    if ($error) {
        $c->{helper}{gp_log_error}=$error;
        if (!defined($c->{helper}{gp_log_warning}) || GP_Mono()-$c->{helper}{gp_log_warning}>=60
            || GP_Mono()<$c->{helper}{gp_log_warning}) {
            GP_NormalLog($c,1,'Could not write diagnostic log; check file path and permissions (get logStatus).');
            $c->{helper}{gp_log_warning}=GP_Mono();
        }
    } else { delete @{$c->{helper}}{qw(gp_log_error gp_log_warning)}; }
}

sub GP_WriteLog {
    my ($path,$level,$text)=@_;
    my $error;
    if (open my $fh,'>>:encoding(UTF-8)',$path) {
        my $ok=print {$fh} POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now()))." $level: $text\n";
        $error="Cannot write $path: $!" unless $ok;
        $error="Cannot close $path: $!" unless close $fh;
    } else { $error="Cannot open $path: $!"; }
    return $error;
}

sub GP_LogDecision {
    my ($c,$r,$row,$debug)=@_;
    my $level=$row->{diagnostic_only} ? 5 : 4;
    $level=3 if $row->{reason} =~ /\A(?:arrival confirmed|actor command dispatched|actor feedback|switch command dispatched|switch command failed)\z/;
    GP_LogAction($c,$r,$row) unless $debug;
    $level=3 if $row->{reason} eq 'qualified unfinished trip restored; waiting for a new return';
    GP_Log($c,$level,'decision',{%$row,resident=>$r,mode=>$debug ? 'debug':'active'});
}

sub GP_LogTrace {
    my ($c,$r,$s,$debug)=@_;
    my $trace=$s->{trace};
    return unless @$trace && ($trace->[-1]{sequence}//0)>($s->{log_sequence}//0);
    # Trace sequences increase monotonically, including after pruning old rows.
    # Only the unlogged tail matters; an idle timer must not revisit 1,000 rows.
    my $first=$#$trace;
    $first-- while $first>0 && ($trace->[$first-1]{sequence}//0)>($s->{log_sequence}//0);
    for my $index ($first..$#$trace) {
        my $row=$trace->[$index];
        next if $row->{sequence}<=($s->{log_sequence}//0);
        # Log3 subscribers may call back synchronously. Claim each row first.
        $s->{log_sequence}=$row->{sequence};
        GP_LogDecision($c,$r,$row,$debug);
    }
}

sub GP_RecordAction {
    my ($c,$r,$s,$now,$reason,$detail)=@_;
    # Only actual output adapters and retained hardware reservations call here.
    # A callback may already have replaced the session: retain the real action
    # in both logs now, without restoring state or granting output permissions.
    if ($s) {
        GP_Trace($s,$now,$reason,$detail);
        GP_LogTrace($c,$r,$s,0);
    } else {
        GP_LogDecision($c,$r,{time=>$now,reason=>$reason,%{$detail//{}}},0);
    }
}

sub GP_Reading { return ((GP_Field($_[0], 'READINGS', {}))->{$_[1]} // {}); }
sub GP_Read { return GP_Reading($_[0], $_[1])->{VAL} // $_[2]; }
sub GP_Controller {
    my ($d) = @_;
    return unless $d && ($d->{TYPE} // '') eq 'GeoPresence';
    return $d if ($d->{SUBTYPE} // '') eq 'controller';
    return $defs{$d->{CONTROLLER} // ''};
}
sub GP_Residents {
    my ($c) = @_;
    return grep { ($defs{$_}{SUBTYPE} // '') eq 'resident' } GP_DeviceNames($c);
}

sub GP_DeviceNames {
    my ($c)=@_;
    # The catalogue is local to one timer callback, never retained between ticks.
    # External device/attribute changes must remain visible on the next check.
    my $work=$c->{helper}{gp_work};
    if ($work && ($work->{runtime}//0)!=($c->{helper}{gp}//0)) {
        delete $work->{devices};
        $work->{runtime}=$c->{helper}{gp};
    }
    return @{$work->{devices}} if $work && $work->{devices};
    my @names=sort grep { ($defs{$_}{TYPE}//'') eq 'GeoPresence'
        && ($defs{$_}{CONTROLLER}//'') eq $c->{NAME} } keys %defs;
    if ($work) { $work->{devices}=\@names; $work->{device_scans}++; }
    return @names;
}

sub GP_Mode {
    my ($name)=@_;
    my $value=GP_Read($name,'mode','disabled');
    return $value if $value =~ /\A(?:active|debug|disabled)\z/;
    return 'learning' if $value eq 'learning' && GP_Field($name,'SUBTYPE','') eq 'resident';
    return 'disabled';
}

sub GP_StoreMode {
    my ($d,$mode)=@_;
    # Operator state belongs in fhem.save, not in a second configuration attr.
    # No userReadings/stateFormat callbacks or action events during a transition.
    setReadingsVal($d,'mode',$mode,POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now())));
}

sub GP_EffectiveMode {
    my ($c,$r,$test)=@_;
    my $cm=GP_Mode($c->{NAME}); my $rm=GP_Mode($r);
    return 'disabled' if $cm eq 'disabled' || $rm eq 'disabled';
    return 'learning' if $rm eq 'learning';
    return 'debug' if $test || $cm eq 'debug' || $rm eq 'debug';
    return 'active';
}

sub GP_ModeReason {
    my ($c,$r)=@_;
    return 'Controller is disabled' if GP_Mode($c->{NAME}) eq 'disabled';
    return 'Resident is disabled' if GP_Mode($r) eq 'disabled';
    return 'Resident is learning; observations only' if GP_Mode($r) eq 'learning';
    return 'Controller is in debug mode' if GP_Mode($c->{NAME}) eq 'debug';
    return 'Resident is in debug mode' if GP_Mode($r) eq 'debug';
    return 'Controller and resident are active';
}

sub GP_UpdateModes {
    my ($c)=@_;
    for my $r (GP_Residents($c)) {
        my %values=(effectiveMode=>GP_EffectiveMode($c,$r,0),modeReason=>GP_ModeReason($c,$r));
        # STATE is the FHEM device display, not the resident's presence or a new
        # control reading. Refresh it even when restored mode readings match.
        $defs{$r}{STATE}=$values{effectiveMode};
        for my $key (keys %values) {
            next if GP_Read($r,$key,'') eq $values{$key};
            setReadingsVal($defs{$r},$key,$values{$key},POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now())));
        }
    }
}

sub GP_AffectedResidents {
    my ($c,$d,$change)=@_;
    my $kind=$d->{SUBTYPE}//''; my $name=$d->{NAME};
    return GP_Residents($c) if $kind eq 'controller';
    return ($name) if $kind eq 'resident';
    my %res;
    $res{$d->{PARENT}}=1 if $kind eq 'location';
    if ($kind eq 'rule') {
        $res{$_}=1 for GP_List(GP_Attr($name,'residents',''));
        $res{$_}=1 for GP_List($change->{residents}//'');
    }
    my %actions=($name=>1);
    if ($kind eq 'action') {
        my %targets=map {$_=>1} grep {length} (GP_Attr($name,'target',''),$change->{target}//'');
        for my $other (GP_DeviceNames($c)) {
            $actions{$other}=1 if GP_Field($other,'SUBTYPE','') eq 'action' && $targets{GP_Attr($other,'target','')};
        }
    }
    for my $rule (GP_DeviceNames($c)) {
        next unless GP_Field($rule,'SUBTYPE','') eq 'rule';
        my $uses=$kind eq 'action' && $actions{GP_Attr($rule,'action','')};
        # Deleting a location referenced by a shared rule affects every member.
        $uses ||= $kind eq 'location' && (grep {$_ eq $name} GP_List(GP_Attr($rule,'locations','')));
        $uses ||= $kind eq 'location' && GP_Attr($rule,'afterExit','') eq 'location:'.$name;
        $res{$_}=1 for $uses ? GP_List(GP_Attr($rule,'residents','')) : ();
    }
    return sort grep {GP_Field($_,'SUBTYPE','') eq 'resident' && GP_Field($_,'CONTROLLER','') eq $c->{NAME}} keys %res;
}

sub GP_ConfigChangeError {
    my ($c,$d,$change)=@_;
    return unless $c && $init_done;
    return 'Controller configuration requires set '.$c->{NAME}.' mode debug or disabled'
        if ($d->{SUBTYPE}//'') eq 'controller' && GP_Mode($c->{NAME}) eq 'active';
    my @active=grep {GP_EffectiveMode($c,$_,0) eq 'active'} GP_AffectedResidents($c,$d,$change//{});
    return 'Configuration affects active residents: '.join(', ',@active).'; use set RESIDENT mode debug or disabled first' if @active;
    return;
}

sub GP_ConfigChanged {
    my ($c,$d,$change)=@_;
    return unless $c;
    return GP_ResetController($c) if ($d->{SUBTYPE}//'') eq 'controller';
    my @affected=GP_AffectedResidents($c,$d,$change//{});
    delete $c->{helper}{gp_work}{devices} if $c->{helper}{gp_work};
    GP_ResetResident($c,$_) for @affected;
    GP_UpdateModes($c);
}

sub GeoPresence_Define {
    my ($hash, $def) = @_;
    my ($name, $type, $kind, @args) = split /\s+/, $def;
    return 'Usage: define name GeoPresence controller|resident|location|action|rule ...'
        unless GP_Name($name) && exists $GP_ATTRS{$kind // ''};
    if ($hash->{SUBTYPE}) {
        return 'Only the function of an existing location can be modified'
            unless $kind eq 'location' && $hash->{SUBTYPE} eq 'location' && @args==2 && $args[0] eq $hash->{PARENT};
        my $c=GP_Controller($hash);
        my $error=GP_ConfigChangeError($c,$hash); return $error if $error;
        return 'Invalid location function; choose home, outer, approach or place'
            unless $args[1] =~ /\A(?:home|outer|approach|place)\z/;
        $hash->{ROLE}=$args[1];
        GP_ConfigChanged($c,$hash);
        GP_UpdateAttrLists();
        return;
    }
    return 'Only one GeoPresence controller is supported' if $kind eq 'controller'
        && grep {($_->{TYPE}//'') eq 'GeoPresence' && ($_->{SUBTYPE}//'') eq 'controller'} values %defs;
    my %count = (controller => 0, resident => 2, location => 2, action => 2, rule => 1);
    return "Wrong argument count for $kind" unless @args == $count{$kind};
    if ($kind ne 'controller') {
        my $parent = $defs{$args[0]};
        my $expected = $kind eq 'location' ? 'resident' : 'controller';
        return "Missing $expected device $args[0]" unless $parent
            && ($parent->{TYPE} // '') eq 'GeoPresence' && ($parent->{SUBTYPE} // '') eq $expected;
        my $c = GP_Controller($parent);
        my $error=GP_ConfigChangeError($c,{NAME=>$name,SUBTYPE=>$kind,PARENT=>$args[0]});
        return $error if $error;
        $hash->{CONTROLLER} = $c->{NAME};
        $hash->{PARENT} = $args[0];
    }
    if ($kind eq 'resident') {
        return 'Resident must reference an existing ROOMMATE' unless GP_Name($args[1])
            && GP_Field($args[1], 'TYPE', '') eq 'ROOMMATE';
        return 'ROOMMATE already belongs to another GeoPresence resident'
            if grep {GP_Field($_,'ROOMMATE','') eq $args[1]} GP_Residents(GP_Controller($hash));
        $hash->{ROOMMATE} = $args[1];
    } elsif ($kind eq 'location') {
        return 'Invalid location function; choose home, outer, approach or place' unless $args[1] =~ /\A(?:home|approach|outer|place)\z/;
        $hash->{ROLE} = $args[1];
    } elsif ($kind eq 'action') {
        return 'Invalid action type' unless $args[1] =~ /\A(?:door_open|garage_open|notify|switch_on)\z/;
        $hash->{ACTIONTYPE} = $args[1];
    }
    $hash->{SUBTYPE} = $kind;
    $hash->{NOTIFYDEV} = $kind eq 'controller' ? 'global' : '';
    $hash->{STATE} = $kind eq 'controller' || $kind eq 'resident' ? 'disabled' : 'configured';
    # During startup/rereadcfg the state file is loaded AFTER the definitions.
    # A fresh timestamp here would make FHEM discard the older saved mode.
    # GP_Mode supplies disabled until restoration; initialize missing readings
    # only after INITIALIZED/REREADCFG. Interactive defines default immediately.
    GP_StoreMode($hash,'disabled') if $init_done && ($kind eq 'controller' || $kind eq 'resident');
    if ($kind eq 'controller') {
        $hash->{CONTROLLER} = $name;
        GP_ResetController($hash);
    } else {
        GP_ConfigChanged(GP_Controller($hash),$hash);
    }
    GP_UpdateAttrLists($hash);
    return;
}

sub GP_ResetController {
    my ($c,$policy) = @_;
    $policy//='invalidate';
    return unless $c;
    my $previous=$c->{helper}{gp}//{};
    if ($policy eq 'resume' && $init_done) {
        # Capture a live qualified trip when updating from a version which did
        # not yet publish checkpoints. Never preserve a queued output adapter.
        for my $r (keys %{$previous->{prod}//{}}) {
            GP_Checkpoint($c,$r,GP_Config($c,$r,0),$previous->{prod}{$r});
        }
    } elsif ($init_done) {
        GP_ClearCheckpoint($_,'Controller configuration changed') for GP_Residents($c);
    }
    delete $c->{helper}{gp_work}{devices} if $c->{helper}{gp_work};
    GP_StopHTTP($c);
    # A reload must also remove the old FHEMWEB registration. This cannot make
    # that FHEMWEB server safe: the operator must remove it and retarget the proxy.
    for my $path (keys %{$data{FWEXT} // {}}) {
        delete $data{FWEXT}{$path} if ($data{FWEXT}{$path}{GP_OWNER} // '') eq $c->{NAME};
    }
    RemoveInternalTimer($c, 'GeoPresence_Timer') if defined &RemoveInternalTimer;
    my $old = $c->{helper}{gp} // {};
    GP_StoreMode($defs{$_},'disabled') for grep {GP_Mode($_) eq 'learning'} GP_Residents($c);
    delete $GP_AUTH{$_} for GP_Residents($c);
    # Retain observation of already dispatched hardware, never pending intentions.
    # Learning results are manual setup data, not a live reception window or trip.
    # An unconfirmed phone identity must not survive a reset of its authorizing
    # session (including password/configuration changes and module reloads).
    my %learned=map {$_=>$old->{learned}{$_}}
        grep {$old->{learned}{$_}{confirmed}} keys %{$old->{learned}//{}};
    $c->{helper}{gp} = { start => GP_Now(), mono => GP_Mono(), epoch => ($old->{epoch} // 0)+1,
        prod => {}, debug => {}, actors => $old->{actors} // {}, queue => [], ready => 0,
        learned => \%learned,
        resume_pending => $policy eq 'resume' ? {map {$_=>1} GP_Residents($c)} : {} };
    GP_Log($c,3,'session_reset',{reason=>$policy eq 'resume'
        ? 'New session; saved qualified trips await validation; pending actions discarded'
        : 'New session; opening permissions revoked'});
    GP_UpdateModes($c);
    GP_ScheduleTimer($c,0.1) if defined &InternalTimer;
}

sub GP_ResetResident {
    my ($c,$r,$keep)=@_; $keep//='';
    my $rt=$c->{helper}{gp} or return;
    GP_ClearCheckpoint($r,'Resident mode or configuration changed') if $init_done;
    delete $rt->{resume_pending}{$r};
    delete $rt->{prod}{$r}; delete $rt->{debug}{$r};
    delete $rt->{geometry}{debug}{$r}; delete $rt->{geometry}{prod}{$r};
    delete $rt->{geometry_dirty}{$r};
    delete $rt->{learning}{$r} unless $keep eq 'learning';
    delete $rt->{learned}{$r} if !$keep && !($rt->{learned}{$r}//{})->{confirmed};
    GP_StoreMode($defs{$r},'disabled') if $keep ne 'learning' && GP_Mode($r) eq 'learning';
    delete $rt->{errors}{$r};
    @{$rt->{queue}}=grep {$_->{resident} ne $r} @{$rt->{queue}};
    $rt->{resident_start}{$r}=GP_Now();
    $rt->{resident_mono}{$r}=GP_Mono();
    $rt->{resident_generation}{$r}++;
}

sub GeoPresence_Undef {
    my ($hash) = @_;
    my $c = GP_Controller($hash);
    if (($hash->{SUBTYPE} // '') eq 'controller') {
        RemoveInternalTimer($hash, 'GeoPresence_Timer');
        GP_StopHTTP($hash);
        for my $path (keys %{$data{FWEXT} // {}}) {
            delete $data{FWEXT}{$path} if ($data{FWEXT}{$path}{GP_OWNER} // '') eq $hash->{NAME};
        }
        delete $hash->{helper}{gp};
        delete $hash->{helper}{gp_timer_due};
    } else {
        my $error=GP_ConfigChangeError($c,$hash); return $error if $error;
        delete $c->{helper}{gp}{learned}{$hash->{NAME}}
            if $c && ($hash->{SUBTYPE}//'') eq 'resident';
        GP_ConfigChanged($c,$hash);
    }
    return;
}

sub GeoPresence_Delete {
    my ($hash) = @_;
    return unless ($hash->{SUBTYPE} // '') eq 'resident';
    delete $GP_AUTH{$hash->{NAME}};
    return setKeyValue('GeoPresence_'.$hash->{NAME}.'_auth', undef);
}

sub GeoPresence_Attr {
    my ($cmd, $name, $key, $value) = @_;
    my $d = $defs{$name} or return;
    return $cmd eq 'del' ? undef : 'Use set '.$name.' mode active|debug|disabled; mode attributes are not supported'
        if $key eq 'mode' || $key eq 'operatingMode';
    return 'Geometry is received from Geofency; do not configure coordinates or radius'
        if $cmd eq 'set' && ($d->{SUBTYPE}//'') eq 'location' && $key =~ /\A(?:latitude|longitude|radius)\z/;
    return unless $GP_ALLOWED{$key};
    my $kind = $d->{SUBTYPE};
    return "Attribute $key is not valid for $kind" unless grep { $_ eq $key } @{$GP_ATTRS{$kind}};
    return "Attribute $key is not used by the selected sourceMode" if $cmd eq 'set' && $init_done
        && $kind eq 'resident' && !GP_ResidentAttrEnabled(GP_Attr($name,'sourceMode','geofency_phone'),$key);
    return "Attribute $key is not used by the selected trigger or location selector" if $cmd eq 'set' && $init_done
        && $kind eq 'rule' && !GP_RuleAttrEnabled($name,$key);
    return "Attribute $key is not valid for $d->{ACTIONTYPE}" if $cmd eq 'set' && $init_done
        && $kind eq 'action' && !grep {$_ eq $key} @{$GP_ACTION_ATTRS{$d->{ACTIONTYPE}}};
    my $c = GP_Controller($d);
    # Diagnostic settings must not end an active learning window or trip.
    if ($key eq 'debugLog') {
        return 'debugLog must be auto, 0 or 1' if $cmd eq 'set' && (!defined($value) || $value !~ /\A(?:auto|0|1)\z/);
        return;
    }
    if ($key eq 'logFile') {
        return 'logFile needs a text filename; allowed date patterns: %Y %m %d %H %M'
            if $cmd eq 'set' && !GP_LogPathValid($value);
        delete @{$c->{helper}}{qw(gp_log_error gp_log_warning)};
        return;
    }
    my $change={$key=>$cmd eq 'set' ? $value:undef};
    my $error=GP_ConfigChangeError($c,$d,$change); return $error if $error;
    if ($cmd eq 'set') {
        return 'Invalid control character or command separator' if !defined($value) || $value =~ /[\r\n\x00;]/;
        return "Invalid value for $key" if $GP_ENUMS{$key} && !grep {$_ eq $value} @{$GP_ENUMS{$key}};
        if ($key eq 'command' && ($d->{ACTIONTYPE}//'') ne 'notify') {
            my $expected=$d->{ACTIONTYPE} eq 'door_open' ? 'lock unlocked':'on';
            return "command must be $expected" if $value ne $expected;
        }
        return "Invalid positive value for $key" if exists $GP_DEFAULT{$key}
            && (!GP_Number($value) || $value <= 0 || $value > 172800);
        return "$key must not exceed 300 seconds" if $key =~ /\Aarrival_(?:wait_\w+|motion_max_age)\z/ && $value>300;
        return 'Invalid cooldown' if $key eq 'cooldown' && ($value !~ /\A\d+\z/ || $value > 86400);
        return 'Invalid UUID or identifier' if $key =~ /\A(?:deviceId|zoneId|webhookUser)\z/ && !GP_Id($value);
        return 'locationGroup must be a name of 1..64 letters, digits, dots, underscores or hyphens, starting with a letter'
            if $key eq 'locationGroup' && !GP_Group($value);
        if ($key eq 'groups') {
            my @groups=GP_List($value); my %seen;
            return 'groups must list 1..16 distinct group names, separated by commas without spaces'
                unless @groups && @groups<=16 && join(',',@groups) eq $value
                    && !grep {!GP_Group($_) || $seen{$_}++} @groups;
        }
        return 'afterExit must be location:DEVICE or group:GROUP; delete the attribute for no prerequisite'
            if $key eq 'afterExit' && $value !~ /\A(?:location:[A-Za-z][A-Za-z0-9_.-]*|group:[A-Za-z][A-Za-z0-9_.-]{0,63})\z/;
        return 'webhookPath must be a simple path component' if $key eq 'webhookPath' && $value !~ /\A[a-zA-Z][a-zA-Z0-9_-]*\z/;
        return 'webhookPort must be an integer from 1024 to 65535' if $key eq 'webhookPort'
            && ($value !~ /\A[0-9]{4,5}\z/ || $value < 1024 || $value > 65535);
        return 'webhookBindAddress must be a concrete IPv4 address; no wildcard or hostname'
            if $key eq 'webhookBindAddress' && !GP_IPv4($value);
        return 'webhookAllowedPeers must list 1..16 distinct IPv4 addresses separated by commas'
            if $key eq 'webhookAllowedPeers' && !GP_PeerListValid($value);
        if ($kind eq 'resident' && $key =~ /\A(?:deviceId|webhookUser)\z/) {
            return "$key already belongs to another resident" if grep {$_ ne $name && lc GP_Attr($_,$key,'') eq lc($value)} GP_Residents($c);
        }
    }
    # Results belong to this phone identity. Returning to an old ID must not
    # revive a previous phone's setup data; same-ID spelling changes are harmless.
    delete $c->{helper}{gp}{learned}{$name} if $key =~ /\A(?:deviceId|sourceMode|webhookUser)\z/
        && ($cmd ne 'set' || lc($value) ne lc GP_Attr($name,$key,''));
    # AttrFn runs before FHEM commits the attribute. Rebuild on the next tick.
    GP_ConfigChanged($c,$d,$change);
    if ($key =~ /\A(?:sourceMode|trigger|locations|locationGroup|groups)\z/) {
        local $attr{$name}{$key} = $cmd eq 'set' ? $value : $key eq 'sourceMode' ? 'geofency_phone':'';
        GP_UpdateAttrLists();
    }
    return;
}

sub GP_Distance {
    my ($a, $b) = @_;
    my $rad = 3.141592653589793 / 180;
    my $p = sin(($b->{lat}-$a->{lat})*$rad/2)**2
        + cos($a->{lat}*$rad)*cos($b->{lat}*$rad)*sin(($b->{lon}-$a->{lon})*$rad/2)**2;
    $p = 1 if $p > 1;
    return 6371000 * 2 * atan2(sqrt($p), sqrt(1-$p));
}

sub GP_HasGeometry {
    my ($g)=@_;
    return $g && GP_Number($g->{lat}) && abs($g->{lat})<=90
        && GP_Number($g->{lon}) && abs($g->{lon})<=180
        && GP_Number($g->{radius}) && $g->{radius}>0 && $g->{radius}<=100000;
}

sub GP_MissingGeometry {
    my ($cfg)=@_;
    return () unless GP_UsesSource($cfg->{sourceMode},'geo');
    return grep {!GP_HasGeometry($cfg->{zones}{$_})} sort keys %{$cfg->{zones}};
}

sub GP_ValidGeometryRecord {
    my ($g,$r,$zone)=@_;
    return ref($g) eq 'HASH' && GP_HasGeometry($g)
        && ($g->{device}//'') eq lc GP_Attr($r,'deviceId','')
        && ($g->{id}//'') eq lc GP_Attr($zone,'zoneId','')
        && GP_Number($g->{time}) && $g->{time}>0
        && GP_Number($g->{changed}) && $g->{changed}>0 && $g->{changed}<=$g->{time};
}

sub GP_Geometry {
    my ($c,$r,$zone,$debug)=@_;
    my $pool=$debug ? 'debug':'prod';
    my $cache=$c->{helper}{gp}{geometry}{$pool}{$r}//={};
    return $cache->{$zone} if exists $cache->{$zone};
    # Debug starts with a COPY of saved metadata, never with productive runtime
    # observations. It never writes these readings or transfers simulated data.
    my $g=eval {$GP_JSON->decode(GP_Read($zone,'gp_geometry','{}'))};
    $g={} unless GP_ValidGeometryRecord($g,$r,$zone);
    # Reviewed enrollment metadata can prepare a newly defined location without
    # another simulated visit. Only explicit applyGeometry writes it to readings.
    my $learned=GP_Learned($c,$r);
    my $captured=$learned && $learned->{confirmed} ? $learned->{zones}{lc GP_Attr($zone,'zoneId','')}:undef;
    if ($debug && $captured && GP_HasGeometry($captured->{geometry}) && $captured->{time}>=($g->{time}//0)) {
        $g={%{$captured->{geometry}},time=>$captured->{time},changed=>$captured->{time},
            device=>$learned->{device},id=>$captured->{id},blocked=>0};
    }
    return $cache->{$zone}=$g;
}

sub GP_GeometryErrors {
    my ($cfg)=@_;
    return () if $cfg->{sourceMode} eq 'phone_only';
    my @errors;
    for my $role (qw(home outer)) {
        push @errors,"$role location not registered" unless @{$cfg->{roles}{$role}//[]}==1;
    }
    for my $role (qw(home outer approach)) {
        for my $n (@{$cfg->{roles}{$role}//[]}) {
            push @errors,"$n: geometry awaiting Geofency webhook" unless GP_HasGeometry($cfg->{zones}{$n});
        }
    }
    for my $z (values %{$cfg->{zones}}) {
        push @errors,"$z->{name}: conflicting geometry timestamp; waiting for newer webhook" if $z->{blocked};
    }
    for my $pair ([qw(home outer)],[qw(home approach)],[qw(approach outer)]) {
        my ($small)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{$pair->[0]}//[]};
        my ($large)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{$pair->[1]}//[]};
        next unless GP_HasGeometry($small) && GP_HasGeometry($large);
        push @errors,"$pair->[0] is not contained in $pair->[1]"
            if GP_Distance($small,$large)+$small->{radius}>$large->{radius};
    }
    return @errors;
}

sub GP_RevokeGeometry {
    my ($s,$time,$now)=@_;
    delete @{$s}{qw(trip arrival approach automotive motion motion_time desired_status conflict)};
    $s->{zones}={}; $s->{members}={}; $s->{intents}=[]; $s->{queued_phones}=[];
    $s->{phase}='unknown'; $s->{location}='unknown';
    $s->{position_time}=$time if $time>($s->{position_time}//0);
    GP_ResetNegative($s,$time);
    GP_Trace($s,$now,'geometry learned or changed; trip and pending actions revoked');
}

sub GP_UpdateGeometry {
    my ($c,$r,$debug,$s,$e,$cfg,$now)=@_;
    return 'same' unless $e->{kind} eq 'geo';
    return 'stale' unless GP_Fresh($cfg,$e,$now) && GP_AfterStart($s,$cfg,$e)
        && $e->{time}>=($s->{position_time}//0);
    my $old=GP_Geometry($c,$r,$e->{zone},$debug);
    my $g=$e->{geometry};
    return 'stale' unless GP_HasGeometry($g);
    my $different=!GP_HasGeometry($old) || grep {$g->{$_}!=$old->{$_}} qw(lat lon radius);
    return 'stale' if defined($old->{time}) && $e->{time}<$old->{time};
    my $conflict=$different && defined($old->{time}) && $e->{time}==$old->{time};
    return 'stale' if $old->{blocked} && $e->{time}<=($old->{time}//0) && !$conflict;
    my $changed=$different || $old->{blocked};
    my $next=$conflict ? {%$old,blocked=>1} : {%$g,time=>$e->{time},
        changed=>$changed ? $e->{time}:$old->{changed},blocked=>0,
        id=>lc GP_Attr($e->{zone},'zoneId',''),device=>lc GP_Attr($r,'deviceId','')};
    if ($GP_JSON->encode($next) ne $GP_JSON->encode($old)) {
        $c->{helper}{gp}{geometry}{$debug?'debug':'prod'}{$r}{$e->{zone}}=$next;
        $c->{helper}{gp}{geometry_dirty}{$r}{$e->{zone}}=1 unless $debug;
    }
    if ($changed) {
        # Geometry is evaluated before GP_Process. Attribute its reset to this
        # webhook, not to the last phone poll or an earlier location event.
        local $s->{trace_context}={source=>'geo',zone=>$e->{zone},entry=>$e->{entry},
            observed=>$e->{time},received=>$e->{received},event_key=>$e->{key},
            geometry_changes=>join('; ',map {$_ . ': ' . (defined($old->{$_})?$old->{$_}:'unknown') . ' -> ' . $g->{$_}}
                grep {!defined($old->{$_}) || $old->{$_}!=$g->{$_}} qw(lat lon radius))};
        GP_RevokeGeometry($s,$e->{time},$now);
    }
    return $conflict ? 'conflict' : $changed ? 'changed':'same';
}

sub GP_GeometrySync {
    my ($s,$cfg,$e,$now,$mono)=@_;
    return unless $e->{kind} eq 'geo';
    my $zone=$cfg->{zones}{$e->{zone}} or return;
    local $s->{trace_context}={source=>'geo',zone=>$e->{zone},entry=>$e->{entry},
        observed=>$e->{time},received=>$e->{received},event_key=>$e->{key}};
    return if $e->{time}<($s->{position_time}//0);
    $s->{position_time}=$e->{time} if $e->{time}>=($s->{position_time}//0);
    if ($zone->{role} eq 'home' && $e->{entry}) {
        delete $s->{trip};
        $s->{phase}='home'; $s->{location}=$zone->{label}; $s->{desired_status}='home';
        GP_ResetNegative($s,$e->{time});
    } elsif (defined($mono) && $cfg->{geometry_ready} && !$s->{conflict}
        && $zone->{role} eq 'home' && !$e->{entry} && GP_Fresh($cfg,$e,$now)
        && GP_AfterStart($s,$cfg,$e) && $e->{time}>$s->{boundary}
        && $e->{key} && !$s->{seen}{$e->{key}}) {
        GP_RememberEvent($s,$e);
        return GP_Trace($s,$now,'Home departure after geometry update contradicted by newer phone presence')
            if GP_UsesSource($cfg->{sourceMode},'phone') && $s->{phone}{state} eq 'present'
                && ($s->{phone}{latest}//0)>=$e->{time};
        # All old permissions and phone qualifications have been revoked. This
        # same fresh exit can start a NEW suspicion, never confirm departure.
        # Only the changed-geometry batch supplies mono; incomplete geometry
        # and ordinary status-only synchronization cannot create a trip here.
        my $t=GP_StartTrip($s,$e,'local'); $t->{home_exit}=$e->{time}; $t->{leave_mono}=$mono;
        GP_ResetNegative($s,$e->{time});
        $s->{zones}{$e->{zone}}={entry=>0,time=>$e->{time},role=>'home'};
        $s->{phase}='leaving'; $s->{location}='underway';
        $s->{last_observed}=$e->{time}; $s->{last_received}=$e->{received}; $s->{last_key}=$e->{key};
        return GP_Trace($s,$now,'Home departure pending after geometry update; new departure confirmation required',
            {home_exit=>$e->{time},departure_armed=>0});
    }
    GP_Trace($s,$now,'geometry synchronization; no actions');
}

sub GP_PublishGeometry {
    my ($c,$r,$s)=@_;
    my $rt=$c->{helper}{gp};
    for my $zone (sort keys %{$rt->{geometry_dirty}{$r}//{}}) {
        # Reading callbacks can change modes or reload the controller.
        last unless $c->{helper}{gp}==$rt && $rt->{ready}
            && GP_EffectiveMode($c,$r,0) eq 'active' && ($rt->{prod}{$r}//0)==$s;
        my $g=$rt->{geometry}{prod}{$r}{$zone};
        next unless $g && $defs{$zone};
        delete $rt->{geometry_dirty}{$r}{$zone};
        readingsBeginUpdate($defs{$zone});
        readingsBulkUpdate($defs{$zone},'gp_geometry',$GP_JSON->encode($g));
        GP_Profile($c,'geometry_reading_callbacks',$zone,sub {readingsEndUpdate($defs{$zone},1)});
    }
}

sub GP_ApplyGeometry {
    my ($c,$r)=@_;
    my $learned=GP_Learned($c,$r);
    return 'applyGeometry requires debug mode or a disabled resident with confirmed learning data'
        unless GP_EffectiveMode($c,$r,0) eq 'debug' || (GP_Mode($r) eq 'disabled' && $learned && $learned->{confirmed});
    return 'applyGeometry requires a Geofency resident'
        unless GP_UsesSource(GP_Attr($r,'sourceMode','geofency_phone'),'geo');
    my $rt=$c->{helper}{gp};
    return 'Confirm learning with set '.$r.' learnConfirm before applyGeometry'
        if GP_Mode($r) eq 'learning' || $c->{helper}{gp}{learning}{$r} || ($learned && !$learned->{confirmed});
    return 'applyGeometry requires real-time observations; use debugReset and fresh app tests after debugAdvance'
        if (($rt->{debug}{$r}//{})->{debug_offset}//0)!=0;
    my $cfg=GP_Config($c,$r,1);
    my @errors=GP_Validate($c,$r,0,$cfg);
    push @errors,@{$cfg->{geometry_errors}};
    my $now=GP_Now();my %updates;
    for my $zone (sort keys %{$cfg->{zones}}) {
        my $g=GP_Geometry($c,$r,$zone,1);
        unless (GP_ValidGeometryRecord($g,$r,$zone) && !$g->{blocked}
            && $g->{time}<=$now+$cfg->{future_tolerance}) {
            push @errors,"$zone: missing, conflicting or invalid debug geometry; send a fresh Geofency test";
            next;
        }
        my $old=GP_Geometry($c,$r,$zone,0);
        my $different=!GP_HasGeometry($old) || grep {$g->{$_}!=$old->{$_}} qw(lat lon radius);
        next if !$different && !$old->{blocked};
        if (defined($old->{time}) && $g->{time}<=$old->{time}) {
            push @errors,"$zone: production geometry is newer or conflicting at the same time; send a newer Geofency test";
            next;
        }
        # Copy geometry only, never visits, movement, trips or permissions. The
        # original timestamps remain intact; confirmation is not an observation.
        $updates{$zone}=$GP_JSON->encode({map {$_=>$g->{$_}} qw(lat lon radius time changed device id blocked)});
    }
    if (@errors) {
        my %seen;return "Geometry not applied; no readings changed:\n".join("\n",grep {!$seen{$_}++} @errors);
    }
    # Fully validate before changing anything. Revoke this resident's journeys
    # first. FHEM's low-level reading setter updates ordinary statefile data
    # without events, userReadings, stateFormat or output-adapter callbacks.
    GP_ResetResident($c,$r);
    my $stamp=POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime($now));
    setReadingsVal($defs{$_},'gp_geometry',$updates{$_},$stamp) for sort keys %updates;
    GP_Log($c,3,'geometry_applied',{resident=>$r,mode=>'debug',changed=>scalar(keys %updates),
        reason=>'Location geometry explicitly confirmed; trips reset; no actions'});
    return 'Geometry applied for '.scalar(keys %updates).' location(s); trips reset; no actions. '
        .'Geometry is stored in normal readings; use FHEM state saving for persistence.';
}

sub GP_Config {
    my ($c, $r, $debug) = @_;
    $c->{helper}{gp_work}{config_builds}++ if $c->{helper}{gp_work};
    my $source_mode=GP_Attr($r,'sourceMode','geofency_phone');
    my $phone=GP_UsesSource($source_mode,'phone');
    my $cfg = { resident => $r, roommate => $defs{$r}{ROOMMATE}, zones => {}, roles => {}, groups => {}, rules => [],
        allowDoor => GP_Attr($r,'allowDoor',0), allowGarage => GP_Attr($r,'allowGarage',0),
        sourceMode => $source_mode,
        phoneSignalMode => $phone ? GP_Attr($r,'phoneSignalMode','state') : 'disabled',
        proxies => $phone ? [GP_List(GP_Attr($r,'phoneProxies',''))] : [],
        label => GP_Attr($defs{$r}{ROOMMATE},'alias',$defs{$r}{ROOMMATE}) };
    $cfg->{$_} = 0+GP_Attr($c->{NAME},$_,$GP_DEFAULT{$_}) for keys %GP_DEFAULT;
    for my $n (GP_DeviceNames($c)) {
        my $d = $defs{$n};
        if (($d->{SUBTYPE} // '') eq 'location' && $d->{PARENT} eq $r) {
            my $geometry=GP_Geometry($c,$r,$n,$debug);
            my $z = { name=>$n, role=>$d->{ROLE}, id=>lc GP_Attr($n,'zoneId',''),
                lat=>$geometry->{lat}, lon=>$geometry->{lon}, radius=>$geometry->{radius},
                blocked=>$geometry->{blocked}//0, label=>GP_Attr($n,'label',$d->{ROLE} eq 'place' ? $n:$d->{ROLE}), groups=>[GP_List(GP_Attr($n,'groups',''))] };
            $cfg->{zones}{$n} = $z;
            push @{$cfg->{roles}{$z->{role}}}, $n;
            push @{$cfg->{groups}{$_}},$n for @{$z->{groups}};
        }
        if (($d->{SUBTYPE} // '') eq 'rule' && GP_Attr($n,'enabled',1)
            && grep { $_ eq $r } GP_List(GP_Attr($n,'residents',''))) {
            my $a = GP_Attr($n,'action','');
            push @{$cfg->{rules}}, { name=>$n, trigger=>GP_Attr($n,'trigger',''), group=>GP_Attr($n,'locationGroup',''),
                locations=>[GP_List(GP_Attr($n,'locations',''))], afterExit=>GP_Attr($n,'afterExit',''),
                arrivalFilter=>GP_Attr($n,'arrivalFilter','any'),
                cooldown=>0+GP_Attr($n,'cooldown',300), action=>$a,
                type=>GP_Field($a,'ACTIONTYPE',''), params=>{%{$attr{$a}//{}}} };
        }
    }
    $cfg->{geometry_errors}=[GP_GeometryErrors($cfg)];
    $cfg->{geometry_ready}=!@{$cfg->{geometry_errors}} ? 1:0;
    return $cfg;
}

sub GP_ConfigRevision {
    my ($cfg)=@_;
    # Only event diagnostics need the fingerprint; idle validation must not
    # serialize the complete configuration every second. It belongs to this
    # immutable snapshot and is never reused for a later configuration build.
    $cfg->{revision}//=sha256_hex($GP_JSON->encode($cfg));
    return $cfg->{revision};
}

sub GP_Validate {
    my ($c, $only, $activation, $prepared_cfg) = @_;
    return ('Controller missing') unless $c;
    my @errors;
    my @res = defined($only) ? ($only) : GP_Residents($c);
    @res = grep { GP_Mode($_) eq 'active' } @res if $activation && !defined($only);
    for my $name ($c->{NAME},@res) {
        push @errors,"$name: remove obsolete attribute $_; use set mode" for grep {exists $attr{$name}{$_}} qw(mode operatingMode);
    }
    my $transport_error=GP_HTTPConfigError($c);
    push @errors,$transport_error if $transport_error;
    push @errors,$c->{helper}{gp_http_error} if $c->{helper}{gp_http_error};
    my (%devices, %users, %roommates);
    for my $r (GP_Residents($c)) {
        for my $spec ([deviceId=>\%devices], [webhookUser=>\%users]) {
            next unless GP_UsesSource(GP_Attr($r,'sourceMode','geofency_phone'),'geo');
            my $v = lc GP_Attr($r,$spec->[0],'');
            push @errors, "Duplicate $spec->[0] for $r" if length($v) && $spec->[1]{$v}++;
        }
        push @errors, "Duplicate ROOMMATE for $r" if $roommates{$defs{$r}{ROOMMATE}}++;
    }
    for my $r (@res) {
        unless (GP_Field($r,'SUBTYPE','') eq 'resident' && GP_Field($r,'CONTROLLER','') eq $c->{NAME}) {
            push @errors, "Unknown resident $r"; next;
        }
        my $cfg = $prepared_cfg && $prepared_cfg->{resident} eq $r ? $prepared_cfg : GP_Config($c,$r);
        push @errors, "$r: invalid sourceMode" unless grep {$_ eq $cfg->{sourceMode}} @{$GP_ENUMS{sourceMode}};
        if (GP_UsesSource($cfg->{sourceMode},'phone')) {
            push @errors, "$r: phoneSignalMode must be state or measurement"
                unless $cfg->{phoneSignalMode} =~ /\A(?:state|measurement)\z/;
            my %proxy = map {$_=>1} @{$cfg->{proxies}};
            push @errors, "$r: phoneProxies must list the house sensors without duplicates"
                unless @{$cfg->{proxies}} && keys(%proxy)==@{$cfg->{proxies}};
            for my $p (@{$cfg->{proxies}}) {
                push @errors, "$r: invalid PRESENCE proxy $p" unless GP_Field($p,'TYPE','') eq 'PRESENCE';
            }
        }
        if (GP_UsesSource($cfg->{sourceMode},'geo')) {
            push @errors, "$r: deviceId and webhookUser required" unless GP_Id(GP_Attr($r,'deviceId','')) && GP_Id(GP_Attr($r,'webhookUser',''));
            my ($err, $secret) = GP_Auth($r);
            push @errors, "$r: set webhookPassword first" unless !$err && defined($secret) && $secret =~ /\A[0-9a-f]{32}:[0-9a-f]{64}\z/;
            for my $role (qw(home outer)) {
                my @locations=@{$cfg->{roles}{$role}//[]};
                if (@locations!=1) {
                    my $detail=@locations ? 'found '.scalar(@locations).': '.join(', ',@locations)
                        : 'found 0; execute the define/attr commands returned by locationCommands';
                    push @errors, "$r: exactly one $role location required ($detail)";
                }
            }
            push @errors, "$r: at most one approach location allowed" if @{$cfg->{roles}{approach}//[]}>1;
        }
        my %ids;
        for my $n (sort keys %{$cfg->{zones}}) {
            next unless GP_UsesSource($cfg->{sourceMode},'geo');
            my $z = $cfg->{zones}{$n};
            push @errors, "$n: invalid location function; use home, outer, approach or place" unless $z->{role} =~ /\A(?:home|outer|approach|place)\z/;
            my %tags;
            push @errors, "$n: invalid or duplicate groups" if @{$z->{groups}}>16 || grep {!GP_Group($_) || $tags{$_}++} @{$z->{groups}};
            push @errors, "$n: valid unique zoneId required" if !GP_Id($z->{id}) || $ids{$z->{id}}++;
        }
        if ($activation && GP_Mode($c->{NAME}) eq 'active') {
            my $rr = $defs{$r}{ROOMMATE};
            push @errors, "$rr: remove rr_geofenceUUIDs before activation" if length GP_Attr($rr,'rr_geofenceUUIDs','');
            push @errors, "$rr: rr_locationUnderway must be underway" unless GP_Attr($rr,'rr_locationUnderway','') eq 'underway';
            (my $suffix=$rr) =~ s/^rr_//;
            for my $old ("People.Loc.$suffix", "People.handler.$suffix.enter") {
                push @errors, "$old: disable legacy action before activation" if exists($defs{$old}) && !GP_Attr($old,'disable',0);
            }
        }
        for my $rule (@{$cfg->{rules}}) {
            push @errors, GP_ValidateRule($c,$rule,$r,$cfg);
        }
    }
    my %relevant_targets;
    if (defined($only) || $activation) {
        my %selected=map {$_=>1} @res;
        for my $rule (GP_DeviceNames($c)) {
            next unless GP_Field($rule,'SUBTYPE','') eq 'rule' && GP_Attr($rule,'enabled',1);
            next unless grep {$selected{$_}} GP_List(GP_Attr($rule,'residents',''));
            my $target=GP_Attr(GP_Attr($rule,'action',''),'target','');
            $relevant_targets{$target}=1 if length $target;
        }
    }
    my %targets;
    for my $name (GP_DeviceNames($c)) {
        my $d=$defs{$name};
        if (($d->{SUBTYPE}//'') eq 'rule' && GP_Attr($name,'enabled',1)) {
            my @selected=GP_List(GP_Attr($name,'residents','')); my %seen;
            next if (defined($only) || $activation) && !grep {my $r=$_; grep {$_ eq $r} @res} @selected;
            push @errors, "$name: residents required" unless @selected;
            for my $resident (@selected) {
                push @errors,"$name: unknown resident $resident" unless GP_Field($resident,'SUBTYPE','') eq 'resident'
                    && GP_Field($resident,'CONTROLLER','') eq $c->{NAME};
                push @errors,"$name: duplicate resident $resident" if $seen{$resident}++;
            }
        }
        next unless ($d->{SUBTYPE}//'') eq 'action' && $d->{ACTIONTYPE} ne 'notify';
        my $target = GP_Attr($d->{NAME},'target','');
        next unless length $target;
        next if (defined($only) || $activation) && !$relevant_targets{$target};
        my $signature = join('|',$d->{ACTIONTYPE}, GP_Attr($d->{NAME},'positionSignalMode','state'),
            map {GP_Attr($d->{NAME},$_,'')} qw(command contact feedbackDevice stateDevice upperContact lowerContact));
        push @errors, "Conflicting action definitions for $target" if exists($targets{$target}) && $targets{$target} ne $signature;
        $targets{$target}=$signature;
    }
    # Shared rules are checked for each affected resident. Report an identical
    # problem once per validation without discarding different residents' errors.
    my %seen;
    return grep {!$seen{$_}++} @errors;
}

sub GP_ValidateRule {
    my ($c,$rule,$resident,$cfg) = @_;
    my @err; my $name=$rule->{name};
    my $a = $defs{$rule->{action}};
    return ("$name: action missing or in another controller") unless $a && ($a->{SUBTYPE}//'') eq 'action' && ($a->{CONTROLLER}//'') eq $c->{NAME};
    push @err, "$name: invalid trigger; choose arrival, enter or exit" unless $rule->{trigger} =~ /\A(?:arrival|enter|exit)\z/;
    push @err, "$name: invalid arrivalFilter" unless ($rule->{arrivalFilter}//'any') =~ /\A(?:any|vehicle)\z/;
    for my $key (keys %{$attr{$name}//{}}) {
        push @err,"$name: $key is not applicable; remove it explicitly"
            if $key =~ /\A(?:locations|locationGroup|arrivalFilter)\z/ && !GP_RuleAttrEnabled($name,$key);
        push @err,"$name: unsupported rule attribute $key; remove it explicitly" if $key eq 'role' || $key eq 'condition';
    }
    if ($rule->{trigger} =~ /\A(?:enter|exit)\z/) {
        push @err,"$name: choose either locations or locationGroup"
            unless (@{$rule->{locations}} ? 1:0) + (length($rule->{group}) ? 1:0)==1;
        if (@{$rule->{locations}}) {
            my %seen;
            for my $z (@{$rule->{locations}}) {
                push @err, "$name: invalid or duplicate location $z" unless GP_Field($z,'SUBTYPE','') eq 'location'
                    && GP_Field($z,'CONTROLLER','') eq $c->{NAME} && !$seen{$z}++;
                push @err,"$name: location $z belongs to a resident outside this rule"
                    unless grep {$_ eq GP_Field($z,'PARENT','')} GP_List(GP_Attr($name,'residents',''));
            }
            push @err,"$name: no selected location belongs to $resident" unless grep {$cfg->{zones}{$_}} @{$rule->{locations}};
        }
        push @err,"$name: group $rule->{group} has no locations for $resident"
            if length($rule->{group}) && (!GP_Group($rule->{group}) || !@{$cfg->{groups}{$rule->{group}}//[]});
    }
    if (length($rule->{afterExit})) {
        my ($kind,$ref)=split /:/,$rule->{afterExit},2;
        push @err,"$name: invalid afterExit for $resident; choose location:DEVICE or group:GROUP belonging to this resident"
            unless defined($ref) && (($kind eq 'location' && exists($cfg->{zones}{$ref}))
                || ($kind eq 'group' && GP_Group($ref) && @{$cfg->{groups}{$ref}//[]}));
    }
    my $p = $rule->{params};
    if ($rule->{type} eq 'notify') {
        push @err, "$rule->{action}: safe message required" unless GP_SafeText($p->{message}//'');
        push @err, 'pushMsg is not loaded' unless defined &pushMsg;
    } elsif ($rule->{type} eq 'switch_on') {
        push @err, "$rule->{action}: missing target device" unless GP_Name($p->{target}) && exists($defs{$p->{target}});
        push @err, "$rule->{action}: command must be on" unless ($p->{command}//'') eq 'on';
    } else {
        push @err, "$rule->{action}: positionSignalMode must be state or measurement"
            unless ($p->{positionSignalMode}//'state') =~ /\A(?:state|measurement)\z/;
        push @err, "$name: opening actions require confirmed arrival" unless $rule->{trigger} eq 'arrival';
        push @err, "$name: garage action requires arrivalFilter vehicle" if $rule->{type} eq 'garage_open' && $rule->{arrivalFilter} ne 'vehicle';
        my @refs = $rule->{type} eq 'door_open' ? qw(target contact feedbackDevice) : qw(target stateDevice upperContact lowerContact);
        push @err, "$rule->{action}: missing $_ device" for grep {!GP_Name($p->{$_}) || !exists($defs{$p->{$_}})} @refs;
        my $command = $rule->{type} eq 'door_open' ? 'lock unlocked' : 'on';
        push @err, "$rule->{action}: command must be $command" unless ($p->{command}//'') eq $command;
    }
    return @err;
}

sub GP_SafeText {
    my ($s) = @_;
    return defined($s) && length($s) && length($s)<=500 && $s !~ /[\x00-\x1f\x7f;{}\\]/;
}

sub GP_ParseTime {
    my ($s) = @_;
    return unless defined($s) && $s =~ /\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d{1,9})?(Z|[+-]\d\d:\d\d)\z/;
    my ($y,$m,$d,$h,$min,$sec,$frac,$off)=($1,$2,$3,$4,$5,$6,$7//0,$8);
    return if $y<2000 || $y>2100 || $h>23 || $min>59 || $sec>59 || $m<1 || $m>12 || $d<1 || $d>31;
    my $t=eval {timegm($sec,$min,$h,$d,$m-1,$y)};
    return if $@;
    my @check=gmtime($t);
    return unless $check[3]==$d && $check[4]+1==$m && $check[5]+1900==$y;
    if ($off ne 'Z') {
        $off =~ /([+-])(\d\d):(\d\d)/;
        return if $2>23 || $3>59;
        $t -= ($1 eq '+' ? 1 : -1) * ($2*3600+$3*60);
    }
    my $fraction=$frac eq '0' ? '' : ($frac =~ s/0+$//r);
    $fraction='' if $fraction eq '.';
    return ($t+0+$frac, sprintf('%d',$t).$fraction);
}

sub GP_ReadingTime {
    my ($device,$reading)=@_;
    my $s=GP_Reading($device,$reading)->{TIME}//'';
    return unless $s =~ /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\z/;
    my $t=eval {timelocal($6,$5,$4,$3,$2-1,$1)};
    return $@ ? undef : $t;
}

sub GP_FormFieldLabel {
    my ($key,$number)=@_;
    return $key if $key =~ /\A(?:device|id|date|entry|isTest|name|latitude|longitude|radius|motion|currentLatitude|currentLongitude|address|wifiSSID|wifiBSSID|beaconUUID|major|minor|notes)\z/;
    return "extra field $number";
}

sub GP_DecodeForm {
    my ($body)=@_;
    return (undef,'Request too large') if length($body)>16384;
    my %p;my @multiline;
    my %used=map {$_=>1} qw(device id date entry isTest name latitude longitude radius motion currentLatitude currentLongitude);
    for my $pair (split /&/, $body) {
        next unless length $pair;
        my ($k,$v)=split /=/,$pair,2;
        return (undef,'Malformed form data') unless defined $v;
        my $part=0;
        for ($k,$v) {
            return (undef,'Invalid percent encoding') if /%(?![0-9a-fA-F]{2})/;
            tr/+/ /;
            s/%([0-9a-fA-F]{2})/chr(hex($1))/eg;
            $_=eval {decode('UTF-8',$_,FB_CROAK)};
            return (undef,'Invalid UTF-8') if $@;
            my $field=$part ? GP_FormFieldLabel($k,1+keys(%p)) : 'field name';
            # Addresses and other unused metadata may legitimately be multiline.
            # Decision fields and field names remain strict; nothing is trimmed
            # into a valid device ID, timestamp, entry, coordinate or motion.
            my $control=($part && !$used{$k}) ? qr/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/ : qr/[\x00-\x1f\x7f]/;
            return (undef,sprintf('Control character U+%04X in %s',ord($1),$field)) if /($control)/;
            $part++;
        }
        return (undef,'Invalid form field name') unless $k =~ /\A[A-Za-z][A-Za-z0-9_.-]{0,63}\z/;
        return (undef,'Duplicate form field') if exists $p{$k};
        push @multiline,GP_FormFieldLabel($k,1+keys(%p)) if $v =~ /[\t\r\n]/;
        $p{$k}=$v;
        return (undef,'Too many fields') if keys(%p)>50;
    }
    return (\%p,undef,{ignored_multiline=>join(',',@multiline)});
}

sub GP_NewPhone {
    return {state=>'disabled',health=>'disabled',samples=>{},ever_present=>0} if defined($_[0]) && !$_[0];
    return {state=>'unknown',health=>'unknown',samples=>{},ever_present=>0};
}

sub GP_ResetNegative {
    my ($s,$after)=@_;
    my $p=$s->{phone};
    delete @{$p}{qw(negative_since negative_wall negative_first qualified negative_emitted)};
    $p->{negative_generation}=($p->{negative_generation}//0)+1 if defined $after;
    $p->{negative_after}=$after if defined($after) && $after>($p->{negative_after}//0);
}

sub GP_NewState {
    my ($now,$mono,$generation,$source_mode)=@_;
    return {start=>$now, generation=>$generation, phase=>'unknown', zones=>{}, seen=>{}, seen_order=>[],
        boundary=>0, seq=>0, phone=>GP_NewPhone(GP_UsesSource($source_mode,'phone')),
        last_decision=>'initialized', last_reason=>'new session; no qualified trip restored',
        mono=>$mono, wall=>$now, notify_seen=>{}, notify_order=>[], trace=>[], intents=>[]};
}

sub GP_Trace {
    my ($s,$now,$reason,$extra)=@_;
    unless (($extra//{})->{diagnostic_only}) {
        $s->{last_reason}=$reason;
        $s->{last_decision}=($extra // {})->{decision} // $reason;
    }
    push @{$s->{trace}}, {time=>$now,reason=>$reason,sequence=>++$s->{trace_sequence},generation=>$s->{generation},phase=>$s->{phase},
        trip=>$s->{trip} ? $s->{trip}{id} : '',observed=>$s->{last_observed},received=>$s->{last_received},
        event_key=>$s->{last_key},config_revision=>$s->{config_revision},phone_mode=>$s->{phone}{state} eq 'disabled' ? 'disabled':$s->{phone_mode}//'live',
        %{$s->{trace_context}//{}},%{$extra//{}}};
    shift @{$s->{trace}} while @{$s->{trace}}>1000;
}

sub GP_StartTrip {
    my ($s,$event,$scope)=@_;
    return $s->{trip} if $s->{trip};
    delete @{$s}{qw(approach automotive motion motion_time)};
    $s->{trip}={id=>$s->{generation}.':'.++$s->{seq}, start=>$event->{time}, scope=>$scope//'local',
        armed=>0, actions=>{}, home_exit=>undef};
    return $s->{trip};
}

sub GP_Fresh {
    my ($cfg,$e,$now)=@_;
    return $now-$e->{time}<=$cfg->{action_max_age} && $e->{time}<=$now+$cfg->{future_tolerance}
        && $now-$e->{received}<=$cfg->{action_max_age};
}

sub GP_AfterStart {
    my ($s,$cfg,$e)=@_;
    # A validated saved departure already supplies the missing initial context.
    # Its NEW Geo return may arrive immediately after startup, but a pre-start
    # webhook still cannot execute. Other startup states retain their old guard.
    my $recovered=defined($s->{resume_event_floor}) && $s->{resume_event_floor}==$s->{start};
    my $margin=$e->{kind} eq 'geo' && !$recovered
        ? $cfg->{future_tolerance}:0;
    return $e->{time}>$s->{start}+$margin;
}

sub GP_RememberEvent {
    my ($s,$e)=@_;
    return unless $e->{key};
    $s->{seen}{$e->{key}}={motion=>$e->{motion}//'unknown',received=>$e->{received}};
    push @{$s->{seen_order}},$e->{key};
    delete $s->{seen}{shift @{$s->{seen_order}}} while @{$s->{seen_order}}>2000;
}

sub GP_UsefulMotion {
    return ($_[0]//'') =~ /\A(?:automotive|walking|running|cycling)\z/;
}

sub GP_EnrichDuplicate {
    my ($s,$cfg,$e,$now,$mono)=@_;
    my $seen=$s->{seen}{$e->{key}};
    my $zone=$cfg->{zones}{$e->{zone}//''}//{};
    my $previous=$s->{zones}{$e->{zone}//''}//{};
    # Only missing transport evidence in the current arrival section can be
    # filled in. No replay of visits, rules, departure or completed arrivals.
    return unless ref($seen) eq 'HASH' && !GP_UsefulMotion($seen->{motion}) && GP_UsefulMotion($e->{motion})
        && $e->{kind} eq 'geo' && $e->{entry} && ($zone->{role}//'') =~ /\A(?:home|approach)\z/
        && $cfg->{geometry_ready} && !$s->{conflict} && $s->{trip} && $s->{trip}{armed}
        && $previous->{entry} && $previous->{time}==$e->{time} && $e->{time}>$s->{boundary}
        && $e->{time}>=($s->{position_time}//0) && $e->{time}>=($s->{motion_time}//0)
        && !(($s->{motion_time}//0)==$e->{time} && GP_UsefulMotion($s->{motion}));
    $seen->{motion}=$e->{motion};
    $s->{motion}=$e->{motion}; $s->{motion_time}=$e->{time};
    $s->{automotive}=$e->{time} if $e->{motion} eq 'automotive';
    # Keep the first receipt and original observation time. A retry cannot
    # refresh motion freshness or restart the Home wait.
    my $enriched={%$e,received=>$seen->{received},role=>$zone->{role}};
    if (my $p=$s->{arrival}) {
        $p->{event}{motion}=$e->{motion} if ($p->{event}{key}//'') eq $e->{key};
        GP_BeginArrival($s,$cfg,$enriched,$now,$mono);
    }
    GP_Trace($s,$now,'duplicate event enriched with motion',{motion=>$e->{motion},motion_time=>$e->{time}});
    return 1;
}

sub GP_MergeBatchMotion {
    my (@events)=@_;
    my %first;
    for my $e (@events) {
        next unless $e->{kind} eq 'geo' && $e->{key};
        my $prior=$first{$e->{key}};
        if (!$prior) { $first{$e->{key}}=$e; next; }
        # Make a richer duplicate available BEFORE any arrival in this batch
        # can consume the trip (including a simultaneous phone confirmation).
        $prior->{motion}=$e->{motion} if !GP_UsefulMotion($prior->{motion}) && GP_UsefulMotion($e->{motion});
    }
}

sub GP_Arm {
    my ($s,$cfg,$e,$now,$mono,$scope,$previous_position)=@_;
    # Measurement timestamps order evidence. A latched positive state remains
    # current until a transition or fault; an old timestamp does not imply absence.
    # A short handover preserves this continuity in either source mode, including
    # its veto of contradictory Geo departures before another room sees the phone.
    if (GP_UsesSource($cfg->{sourceMode},'phone') && $s->{phone}{state} eq 'present' && (($s->{phone}{latest}//0)>=$e->{time}
        || $s->{phone}{health} eq 'handover'
        || (($cfg->{phoneSignalMode}//'state') eq 'state' && $s->{phone}{health} eq 'held'))) {
        # Held presence vetoes this outer observation, but does not disprove an
        # earlier Home exit observed AFTER the last actual positive phone sample.
        # Retain only that unarmed local suspicion, never remote/work permissions.
        my $home=$s->{trip};
        my $retain=$home && !$home->{armed} && ($home->{scope}//'') eq 'local'
            && defined($home->{home_exit}) && $home->{home_exit}>($s->{phone}{latest}//0);
        delete @{$s}{qw(trip arrival approach automotive motion motion_time)};
        my $detail={phone_state=>$s->{phone}{state},phone_health=>$s->{phone}{health},phone_latest=>$s->{phone}{latest}};
        if ($retain) {
            $s->{trip}={map({$_=>$home->{$_}} qw(id start home_exit leave_mono)),scope=>'local',armed=>0,actions=>{}};
            $s->{phase}='leaving'; $s->{location}='underway';
            # The rejected event must neither supersede earlier negative samples
            # nor restart their running qualification or demand a new transition.
            $s->{position_time}=$previous_position;
            GP_Trace($s,$now,'departure rejected; pending Home exit retained',{%$detail,home_exit=>$home->{home_exit}});
            return 0;
        }
        $s->{phase}='home'; $s->{location}='home'; $s->{desired_status}='home';
        $s->{position_time}=$s->{phone}{latest} if $s->{phone}{latest}>($s->{position_time}//0);
        GP_ResetNegative($s,$s->{position_time});
        GP_Trace($s,$now,'departure contradicted by current local presence',$detail);
        return 0;
    }
    # A renewed, accepted departure ends the previous arrival section even
    # when the physical trip remains open and no approach exit was delivered.
    delete @{$s}{qw(approach automotive motion motion_time)} if $s->{phase} eq 'returning';
    GP_CancelArrival($s,$now,'new departure observation');
    my $trip=GP_StartTrip($s,$e,$scope);
    $trip->{scope}='remote' if ($scope//'') eq 'remote';
    unless ($trip->{armed}) {
        $trip->{armed}=1; $trip->{away_time}=$e->{time}; $trip->{away_mono}=$mono;
        $trip->{away_reason}=$e->{zone}//$e->{kind};
    }
    $s->{phase}='away';
    return 1;
}

sub GP_VehicleEligible {
    my ($s,$cfg,$now)=@_;
    return 1 if defined($s->{automotive}) && $now-$s->{automotive}<=$cfg->{motion_max_age};
    return 0 if ($s->{motion}//'') =~ /\A(?:walking|running|cycling)\z/ && $now-($s->{motion_time}//0)<=$cfg->{motion_max_age};
    return $s->{trip} && ($s->{trip}{scope}//'') eq 'remote';
}

# Explicit membership is separate from the display's geometric/age inference.
# Missing exits and expired readings never manufacture a group exit.
sub GP_LocationEvents {
    my ($s,$cfg,$e)=@_;
    my $zone=$e->{zone}; my $members=$s->{members}//={};
    my $previous=$members->{$zone};
    my %before=map {my $g=$_; $g=>scalar(grep {$members->{$_} && $members->{$_}{entry}} @{$cfg->{groups}{$g}})}
        @{$cfg->{zones}{$zone}{groups}};
    $s->{zone_visits}{$zone}++ if $e->{entry} && (!$previous || !$previous->{entry});
    $s->{zone_visits}{$zone}//=1;
    $members->{$zone}={entry=>$e->{entry},time=>$e->{time}};
    my @events=({%$e,selector=>'location:'.$zone});
    my $exits=$s->{trip} ? ($s->{trip}{exits}//={}):undef;
    # A confirmed return can leave intents awaiting dispatch in this same batch.
    # Reentry must also revoke their evidence in the just-completed trip.
    my $completed=($s->{last_trip}//{})->{exits};
    delete $completed->{'location:'.$zone} if $completed && $e->{entry};
    if ($exits) {
        if ($e->{entry}) { delete $exits->{'location:'.$zone}; }
        elsif (!$previous || $previous->{entry}) { $exits->{'location:'.$zone}=$e->{time}; }
    }
    for my $group (@{$cfg->{zones}{$zone}{groups}}) {
        my $inside=grep {$members->{$_} && $members->{$_}{entry}} @{$cfg->{groups}{$group}};
        delete $exits->{'group:'.$group} if $exits && $e->{entry};
        delete $completed->{'group:'.$group} if $completed && $e->{entry};
        my $transition=$e->{entry} ? !$before{$group} : !$inside && ($before{$group} || !$previous);
        next unless $transition;
        $s->{group_visits}{$group}++ if $e->{entry};
        $s->{group_visits}{$group}//=1;
        $exits->{'group:'.$group}=$e->{time} if $exits && !$e->{entry};
        push @events,{%$e,group=>$group,selector=>'group:'.$group};
    }
    return @events;
}

sub GP_ExitEvidence {
    my ($s,$reference,$time)=@_;
    my $trip=$s->{trip} or return;
    my $exit=($trip->{exits}//{})->{$reference};
    return defined($exit) && $exit>=$trip->{start} && $exit<$time ? $exit:undef;
}

sub GP_Rules {
    my ($s,$cfg,$trigger,$e,$now,$mono)=@_;
    for my $rule (@{$cfg->{rules}}) {
        next unless $rule->{trigger} eq $trigger;
        if ($trigger ne 'arrival') {
            next if length($rule->{group}//'') ? ($e->{group}//'') ne $rule->{group}
                : length($e->{group}//'') || !grep {$_ eq ($e->{zone}//'')} @{$rule->{locations}};
        }
        my $skip=sub {GP_Trace($s,$now,$_[0],{rule=>$rule->{name},decision=>'suppressed'})};
        my $after=$rule->{afterExit}//'';
        my $exit=length($after) ? GP_ExitEvidence($s,$after,$e->{time}):undef;
        if (length($after) && !defined($exit)) { $skip->('required prior exit not observed in this trip'); next; }
        if (($rule->{arrivalFilter}//'any') eq 'vehicle' && !(exists($e->{arrival_vehicle_eligible})
            ? $e->{arrival_vehicle_eligible} : GP_VehicleEligible($s,$cfg,$now))) {
            $skip->('no qualifying car or remote evidence, or current walking/cycling'); next;
        }
        my $type=$rule->{type};
        if ($trigger eq 'arrival' || GP_IsOpening($type)) {
            unless (GP_UsesSource($cfg->{sourceMode},'geo')) { $skip->('source profile does not authorize arrival actions'); next; }
            unless ($cfg->{geometry_ready}) { $skip->('geometry not ready'); next; }
            unless ($s->{trip} && $s->{trip}{armed} && !$s->{conflict}) { $skip->('departure not confirmed'); next; }
            if ($e->{time}-$s->{trip}{away_time}<$cfg->{minimum_away}
                || $mono-$s->{trip}{away_mono}<$cfg->{minimum_away}) { $skip->('return before minimum away time'); next; }
        }
        my %history=length($after) ? (after_exit=>$after,exit_time=>$exit,trip=>$s->{trip}{id}):();
        if (GP_IsOpening($type)) {
            unless ($trigger eq 'arrival') { $skip->('opening requires confirmed arrival'); next; }
            if (($type eq 'door_open' && !$cfg->{allowDoor}) || ($type eq 'garage_open' && !$cfg->{allowGarage})) {
                $skip->('resident has no permission for this actor'); next;
            }
            my $key=join('|',$s->{trip}{id},$type,$rule->{params}{target}//'');
            if ($s->{trip}{actions}{$key}++) { $skip->('action already consumed in this trip'); next; }
            push @{$s->{intents}}, {kind=>$type,key=>$key,trip=>$s->{trip}{id},rule=>$rule->{name},%history,
                params=>{%{$rule->{params}}},e=>{%$e},generation=>$s->{generation}};
        } else {
            my $visit=$trigger eq 'arrival' || length($after) ? $s->{trip}{id}
                : length($e->{group}//'') ? ($s->{group_visits}{$e->{group}}//0) : ($s->{zone_visits}{$e->{zone}}//0);
            my $key=join('|',$rule->{action},$trigger,$visit,$e->{selector}//'arrival');
            my $label=$type eq 'switch_on' ? 'switch' : 'notification';
            if ($s->{notify_seen}{$key}) { $skip->("$label already consumed"); next; }
            if (defined($s->{notify_last}{$rule->{action}}) && $now-$s->{notify_last}{$rule->{action}}<$rule->{cooldown}) {
                $skip->("$label cooldown"); next;
            }
            $s->{notify_seen}{$key}=1; $s->{notify_last}{$rule->{action}}=$now;
            push @{$s->{notify_order}}, $key;
            delete $s->{notify_seen}{shift @{$s->{notify_order}}} while @{$s->{notify_order}}>2000;
            push @{$s->{intents}}, {kind=>$type,key=>$key,rule=>$rule->{name},params=>{%{$rule->{params}}},%history,
                e=>{%$e},generation=>$s->{generation}};
        }
    }
}

sub GP_CancelArrival {
    my ($s,$now,$reason)=@_;
    return unless delete $s->{arrival};
    GP_Trace($s,$now,'arrival cancelled',{confirmation=>$reason});
}

sub GP_InterruptsArrival {
    my ($s,$cfg,$e)=@_;
    return $s->{arrival} && $e->{kind} eq 'geo' && !$e->{entry}
        && $e->{time}>=$s->{arrival}{event}{time}
        && (($cfg->{zones}{$e->{zone}}//{})->{role}//'') =~ /\A(?:home|approach|outer)\z/;
}

sub GP_ArrivalMotion {
    my ($s,$cfg,$now)=@_;
    my $motion=$s->{motion}//'unknown';
    my $age=$now-($s->{motion_time}//0);
    # A useful foot observation survives an empty Home payload. Faster waits
    # require newer evidence than the independent garage permission does.
    my $limit=$motion eq 'walking' ? $cfg->{motion_max_age} : $cfg->{arrival_motion_max_age};
    return 'unknown' unless $motion =~ /\A(?:walking|running|cycling|automotive)\z/
        && $age>=-$cfg->{future_tolerance} && $age<=$limit;
    return $motion;
}

sub GP_BeginArrival {
    my ($s,$cfg,$e,$now,$mono)=@_;
    # Status-only synchronization and premature returns cannot acquire a new
    # opening permission merely by waiting out minimum_away at Home.
    unless ($s->{trip} && $s->{trip}{armed} && !$s->{conflict}
        && $e->{time}-$s->{trip}{away_time}>=$cfg->{minimum_away}
        && $mono-$s->{trip}{away_mono}>=$cfg->{minimum_away}) {
        return GP_Arrive($s,$cfg,$e,$now,$mono);
    }
    my $p=$s->{arrival};
    if (!$p) {
        # Count from server receipt, never from a phone's possibly delayed date.
        # The reorder window is part of the wait, not an additional full wait.
        my $elapsed=$now-$e->{received}; $elapsed=0 if $elapsed<0;
        $p=$s->{arrival}={event=>{%$e},trip=>$s->{trip}{id},generation=>$s->{generation},
            start_mono=>$mono-$elapsed,started=>$e->{received},
            vehicle_eligible=>GP_VehicleEligible($s,$cfg,$now)?1:0};
    }
    $p->{latest_home}={%$e} if ($e->{role}//'') eq 'home';
    if (defined($p->{wait}) && ($e->{motion}//'') !~ /\A(?:walking|running|cycling|automotive)\z/) {
        # Repeated entry webhooks with no new evidence neither restart the wait
        # nor allow a walking veto to expire into a remote garage permission.
        return;
    } elsif (defined($p->{wait})) {
        $p->{vehicle_eligible}=GP_VehicleEligible($s,$cfg,$now)?1:0;
    }
    my $motion=GP_ArrivalMotion($s,$cfg,$now);
    my $wait=$cfg->{'arrival_wait_'.$motion};
    my $changed=!defined($p->{wait}) || $p->{wait}!=$wait || $p->{motion} ne $motion;
    $p->{motion}=$motion; $p->{motion_time}=$s->{motion_time}; $p->{wait}=$wait;
    $p->{due_mono}=$p->{start_mono}+$wait;
    $p->{deadline}=$p->{started}+$wait;
    $s->{phase}='returning';
    delete $s->{approach};
    GP_Trace($s,$now,'arrival pending',{motion=>$motion,motion_time=>$p->{motion_time},
        wait_seconds=>$wait,deadline=>$p->{deadline}}) if $changed;
}

sub GP_ActionFresh {
    my ($cfg,$e,$now)=@_;
    # Only the module's confirmation path supplies this allowance. Keep the
    # original event date/receipt; deliberate waiting does not turn a late retry
    # into a fresh observation or permit unbounded execution after a timer stall.
    my $allowance=$e->{arrival_wait_budget}//0;
    return $now-$e->{time}<=$cfg->{action_max_age}+$allowance
        && $e->{time}<=$now+$cfg->{future_tolerance}
        && $now-$e->{received}<=$cfg->{action_max_age}+$allowance;
}

sub GP_ConfirmArrival {
    my ($s,$cfg,$now,$mono)=@_;
    my $p=$s->{arrival} or return;
    return if $mono<$p->{due_mono};
    unless ($s->{trip} && $s->{trip}{armed} && $p->{trip} eq $s->{trip}{id}
        && $p->{generation} eq $s->{generation} && !$s->{conflict}
        && $cfg->{geometry_ready} && $s->{phase} eq 'returning'
        && ($s->{zones}{$p->{event}{zone}}//{})->{entry}) {
        return GP_CancelArrival($s,$now,'arrival evidence revoked');
    }
    my $e={%{$p->{event}},arrival_wait_budget=>$p->{wait},
        arrival_vehicle_eligible=>$p->{vehicle_eligible},confirmation=>'timer'};
    unless (GP_ActionFresh($cfg,$e,$now)) {
        GP_CancelArrival($s,$now,'arrival confirmation expired');
        $s->{phase}='away';
        return;
    }
    GP_Arrive($s,$cfg,$e,$now,$mono);
}

sub GP_Arrive {
    my ($s,$cfg,$e,$now,$mono)=@_;
    local $s->{trace_context}={source=>$e->{kind},zone=>$e->{zone}};
    my $pending=delete $s->{arrival};
    # A new local phone return may finish the same provisional Home arrival.
    # Preserve its motion-based garage decision across the confirmation wait.
    $e={%$e,arrival_vehicle_eligible=>$pending->{vehicle_eligible}} if $pending && $e->{kind} eq 'phone_present';
    GP_Trace($s,$now,'arrival confirmed', {source=>$e->{kind}, time_observed=>$e->{time},changed=>$s->{phase} ne 'home' ? 1:0,
        observed=>$e->{time},received=>$e->{received},event_key=>$e->{key},
        confirmation=>$e->{confirmation}//($e->{kind} eq 'phone_present' ? 'phone':'status only'),
        motion=>$pending ? $pending->{motion}:$s->{motion},wait_seconds=>$pending ? $mono-$pending->{start_mono}:0});
    GP_Rules($s,$cfg,'arrival',$e,$now,$mono);
    $s->{last_trip}=$s->{trip} if $s->{trip};
    delete $s->{trip};
    my ($home)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{home}//[]};
    # Return makes distant memberships obsolete, but is not their exit event.
    # Keep overlapping/home memberships so another Home webhook is no new visit.
    if (GP_HasGeometry($home)) {
        for my $name (keys %{$s->{members}//{}}) {
            my $zone=$cfg->{zones}{$name};
            delete $s->{members}{$name} if GP_HasGeometry($zone)
                && GP_Distance($home,$zone)>$home->{radius}+$zone->{radius};
        }
    }
    $s->{phase}='home';
    $s->{location}='home';
    my $boundary=($s->{position_time}//0)>$e->{time} ? $s->{position_time}:$e->{time};
    $s->{boundary}=$boundary if $boundary>$s->{boundary};
    delete @{$s}{qw(approach automotive conflict)};
    $s->{desired_status}='home';
    GP_ResetNegative($s,$boundary);
}

sub GP_CheckClock {
    my ($s,$cfg,$now,$mono)=@_;
    if (abs(($now-$s->{wall})-($mono-$s->{mono}))>$cfg->{future_tolerance}) {
        delete @{$s}{qw(trip arrival approach automotive motion motion_time position_time desired_status resume_event_floor)};
        $s->{phone}=GP_NewPhone(GP_UsesSource($cfg->{sourceMode},'phone'));
        $s->{zones}={}; $s->{members}={}; $s->{phase}='unknown'; $s->{boundary}=0; $s->{start}=$now;
        $s->{intents}=[]; $s->{generation}.=':clock';
        GP_Trace($s,$now,'clock discontinuity; permissions revoked');
    }
    $s->{wall}=$now; $s->{mono}=$mono;
}

sub GP_Contradiction {
    my ($a,$b,$cfg)=@_;
    return 0 unless $a->{time}==$b->{time};
    return $a->{entry}!=$b->{entry} if $a->{zone} eq $b->{zone};
    my ($az,$bz)=map {$cfg->{zones}{$_->{zone}}} ($a,$b);
    return 0 unless GP_HasGeometry($az) && GP_HasGeometry($bz);
    my $dist=GP_Distance($az,$bz);
    return 1 if $a->{entry} && $b->{entry} && $dist>$az->{radius}+$bz->{radius};
    return 1 if !$a->{entry} && $b->{entry} && $dist+$bz->{radius}<=$az->{radius};
    return 1 if $a->{entry} && !$b->{entry} && $dist+$az->{radius}<=$bz->{radius};
    return 0;
}

sub GP_Process {
    my ($s,$cfg,$e,$now,$mono)=@_;
    # Keep the cause on every decision made for this observation. Dynamic scope
    # prevents a later timer or actuator result from inheriting an old source.
    local $s->{trace_context}={source=>$e->{kind},zone=>$e->{zone}};
    $s->{intents}=[];
    return GP_Trace($s,$now,'observation source disabled by sourceMode')
        if ($e->{kind} eq 'geo' && !GP_UsesSource($cfg->{sourceMode},'geo'))
            || ($e->{kind} =~ /^phone_/ && !GP_UsesSource($cfg->{sourceMode},'phone'));
    $s->{last_observed}=$e->{time}; $s->{last_received}=$e->{received};
    $s->{last_key}=$e->{key}; $s->{config_revision}=GP_ConfigRevision($cfg);
    GP_CheckClock($s,$cfg,$now,$mono);
    GP_Trace($s,$now,'observation received',{diagnostic_only=>1,source=>$e->{kind},zone=>$e->{zone},entry=>$e->{entry},
        motion=>$e->{motion},zone_position=>$e->{zone_position},current_position=>$e->{current_position}});
    # Held startup snapshots synchronize status only. They cannot supersede any
    # current-session observation or participate in an opening decision.
    if ($e->{kind} eq 'phone_snapshot' || $e->{kind} eq 'phone_absent') {
        return GP_Trace($s,$now,'phone observation belongs to previous session')
            unless ($e->{generation}//'') eq $s->{generation};
    }
    if ($e->{kind} eq 'phone_snapshot') {
        return GP_Trace($s,$now,'startup phone snapshot superseded') if defined($s->{position_time}) || $s->{trip};
        $s->{phase}='home'; $s->{location}='home'; $s->{desired_status}='home';
        $s->{position_time}=$s->{start};
        GP_ResetNegative($s,$s->{start});
        return GP_Trace($s,$now,'held phone snapshot; status only');
    }
    if ($e->{kind} eq 'phone_absent') {
        my $p=$s->{phone};
        return GP_Trace($s,$now,'phone absence qualification revoked') unless ($e->{negative_generation}//-1)==($p->{negative_generation}//0);
        return GP_Trace($s,$now,'phone absence older than current position') if $e->{time}<($s->{position_time}//0)
            || (defined($p->{negative_after}) && $e->{time}<=$p->{negative_after});
        # Keep the source observation time. After 180 s of qualification its age
        # may exceed action_max_age; this event never invokes action rules.
        if ($cfg->{geometry_ready} && $s->{trip} && !$s->{trip}{armed} && defined($s->{trip}{home_exit})
            && $e->{time}>$s->{trip}{home_exit} && $e->{negative_wall}>=$s->{trip}{home_exit}) {
            my $t=$s->{trip};
            $t->{armed}=1; $t->{away_time}=$e->{negative_wall}; $t->{away_mono}=$e->{negative_since};
            $t->{away_reason}='Home exit and qualified phone absence';
        }
        my $changed=$s->{phase} ne 'away' ? 1:0;
        GP_CancelArrival($s,$now,'new phone absence');
        $s->{position_time}=$e->{time};
        $s->{phase}='away'; $s->{desired_status}='absent';
        return GP_Trace($s,$now,'phone absence qualified',{changed=>$changed,departure_armed=>$s->{trip} && $s->{trip}{armed} ? 1:0});
    }
    # A positive source observation at/after an unarmed Home exit disproves
    # that suspicion. Even a late sample can revoke it without becoming a
    # fresh arrival or rewinding a newer position. Never use a future sample.
    if ($e->{kind} eq 'phone_present' && $e->{time}<=$now && $s->{trip} && !$s->{trip}{armed}
        && defined($s->{trip}{home_exit}) && $e->{time}>=$s->{trip}{home_exit}) {
        delete $s->{trip};
        GP_Trace($s,$now,'pending Home departure revoked by newer phone presence');
    }
    return GP_Trace($s,$now,'event too old or future') unless GP_Fresh($cfg,$e,$now);
    if (!GP_AfterStart($s,$cfg,$e)) {
        return GP_Trace($s,$now,'event precedes session boundary');
    }
    if ($e->{key}) {
        if ($s->{seen}{$e->{key}}) {
            return if GP_EnrichDuplicate($s,$cfg,$e,$now,$mono);
            return GP_Trace($s,$now,'duplicate event');
        }
        GP_RememberEvent($s,$e);
    }
    if ($e->{time}<($s->{position_time}//0)) {
        my $p=$s->{arrival};
        # Do not rewind current position, but a delayed exit within the pending
        # interval disproves uninterrupted Home membership. If a newer Home
        # entry is already known, its receipt starts a NEW complete wait.
        if (GP_InterruptsArrival($s,$cfg,$e)) {
            my $latest=$p->{latest_home};
            GP_CancelArrival($s,$now,'delayed exit interrupted Home membership');
            delete @{$s}{qw(motion motion_time)} if ($s->{motion_time}//0)<=$e->{time};
            delete $s->{automotive} if ($s->{automotive}//0)<=$e->{time};
            if ($latest && $latest->{time}>$e->{time}) {
                GP_BeginArrival($s,$cfg,$latest,$now,$mono);
            } else {
                $s->{phase}='away'; $s->{desired_status}='absent';
            }
        }
        return GP_Trace($s,$now,'observation older than current position');
    }
    if ($e->{kind} eq 'phone_present') {
        my $p=$s->{phone};
        if ($s->{trip} && $s->{trip}{armed} && !$e->{arrival}) {
            delete $s->{trip}; GP_CancelArrival($s,$now,'continuous local presence');
            GP_Trace($s,$now,'continuous local presence; departure revoked');
        }
        $s->{position_time}=$e->{time};
        return GP_Arrive($s,$cfg,$e,$now,$mono);
    }
    return unless $e->{kind} eq 'geo';
    my $zone=$cfg->{zones}{$e->{zone}} or return;
    return GP_GeometrySync($s,$cfg,$e,$now) unless $cfg->{geometry_ready} && GP_HasGeometry($zone);
    my $previous=$s->{zones}{$e->{zone}};
    return GP_Trace($s,$now,'older zone observation') if $previous && $e->{time}<$previous->{time};
    for my $name (keys %{$s->{zones}}) {
        if (GP_Contradiction($e,{%{$s->{zones}{$name}},zone=>$name},$cfg)) {
            $s->{conflict}=1; delete $s->{trip}; GP_CancelArrival($s,$now,'contradictory locations');
            return GP_Trace($s,$now,'contradictory locations at same time');
        }
    }
    return GP_Trace($s,$now,'event before completed arrival') if $e->{time}<=$s->{boundary};
    delete $s->{conflict};
    my $previous_position=$s->{position_time};
    $s->{position_time}=$e->{time};
    my $role=$zone->{role}; $e->{role}=$role;
    # Geometrically disjoint or nested contradictory older observations are stale.
    for my $other (keys %{$s->{zones}}) {
        next if $other eq $e->{zone};
        my $v=$s->{zones}{$other}; my $oz=$cfg->{zones}{$other} or next;
        next if $v->{time}>=$e->{time};
        next unless GP_HasGeometry($oz);
        my $dist=GP_Distance($zone,$oz);
        if (($e->{entry} && $dist>$zone->{radius}+$oz->{radius})
            || (!$e->{entry} && $dist+$oz->{radius}<=$zone->{radius})) { $v->{entry}=0; }
    }
    $s->{zones}{$e->{zone}}={entry=>$e->{entry},time=>$e->{time},role=>$role};
    $s->{location}=$e->{entry} ? $zone->{label} : 'underway';
    my ($home)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{home}//[]};
    my ($outer)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{outer}//[]};
    my $far = GP_HasGeometry($home)
        && GP_Distance($zone,$home)>$zone->{radius}+$home->{radius}+$cfg->{departure_margin};
    my $remote = ($role eq 'outer' && !$e->{entry})
        || (GP_HasGeometry($outer) && GP_Distance($zone,$outer)>$zone->{radius}+$outer->{radius});
    GP_CancelArrival($s,$now,'Home or surrounding area exited')
        if !$e->{entry} && $role =~ /\A(?:home|approach|outer)\z/;
    if (!$e->{entry} && $role eq 'home') {
        my $t=GP_StartTrip($s,$e,'local'); $t->{home_exit}=$e->{time}; $t->{leave_mono}=$mono;
        GP_ResetNegative($s,$e->{time});
        $s->{phase}='leaving';
    }
    my $area_exit=!$e->{entry} && ($role eq 'approach' || $role eq 'outer');
    # Without independent indoor sensors, a near-identical surrounding circle
    # cannot provide the extra distance evidence. Use its nearest boundary.
    if ($area_exit && $cfg->{sourceMode} eq 'geofency_only'
        && $zone->{radius}-GP_Distance($zone,$home)-$home->{radius}<=$cfg->{departure_margin}) {
        $area_exit=0;
        GP_Trace($s,$now,'departure area too close to Home; distance evidence required');
    }
    if ($area_exit || $far) {
        return unless GP_Arm($s,$cfg,$e,$now,$mono,$remote ? 'remote':'local',$previous_position);
        $s->{desired_status}='absent' if $s->{phase} eq 'away';
    }
    if (!$e->{entry} && ($role eq 'approach' || $role eq 'home')) {
        delete @{$s}{qw(approach automotive motion motion_time)};
    }
    if ($e->{entry} && ($role eq 'home' || $role eq 'approach')) {
        GP_ResetNegative($s,$e->{time});
        # Missing/unknown motion and stationary supply no new transport evidence.
        # Keep the last useful observation and its ORIGINAL time in this section;
        # an empty Home payload must neither erase walking nor refresh its TTL.
        if (($e->{motion}//'') =~ /\A(?:automotive|walking|running|cycling)\z/) {
            $s->{motion}=$e->{motion}; $s->{motion_time}=$e->{time};
            $s->{automotive}=$e->{time} if $e->{motion} eq 'automotive';
        }
    }
    for my $event (GP_LocationEvents($s,$cfg,$e)) {
        GP_Rules($s,$cfg,$e->{entry}?'enter':'exit',$event,$now,$mono);
    }
    if ($e->{entry} && ($role eq 'home' || $role eq 'approach')) {
        if ($role eq 'home') { GP_BeginArrival($s,$cfg,$e,$now,$mono); }
        elsif ($s->{arrival}) { GP_BeginArrival($s,$cfg,$e,$now,$mono); }
        elsif ($s->{trip} && $s->{trip}{armed}) {
            $s->{phase}='returning'; $s->{approach}=$mono;
        }
    }
    GP_Trace($s,$now,'zone observation processed',{diagnostic_only=>1,zone=>$e->{zone},entry=>$e->{entry},
        zone_label=>$zone->{label},changed=>!$previous || $previous->{entry}!=$e->{entry} ? 1:0});
    return;
}

sub GP_PhoneSamples {
    my ($cfg,$now)=@_;
    return {} unless GP_UsesSource($cfg->{sourceMode},'phone');
    my %samples;
    for my $p (@{$cfg->{proxies}}) {
        my $d=$defs{$p}//{};
        my $interval=$d->{INTERVAL_NORMAL};
        unless (defined $interval) { my @def=split /\s+/,$d->{DEF}//''; $interval=$def[3]//60; }
        $interval=60 unless GP_Number($interval) && $interval>0;
        my $present=$d->{INTERVAL_PRESENT}//$interval;
        $interval=$present if GP_Number($present) && $present>$interval;
        my $state=GP_Read($p,'state','unknown');
        my $value=GP_Read($p,'presence','unknown');
        my $t=GP_ReadingTime($p,'presence');
        my $healthy=$state =~ /\A(?:present|absent)\z/ && $state eq $value && !GP_Attr($p,'disable',0)
            && !(($d->{helper}//{})->{DISABLED})
            && ($d->{STATE}//'') !~ /\A(?:disconnected|disabled|error|timeout)\z/i;
        $samples{$p}={value=>$value,time=>$t,ttl=>2*$interval+30,healthy=>$healthy?1:0};
    }
    return \%samples;
}

# State sources latch present/absent until a change or fault. Measurement sources
# additionally require periodic measurements and a TTL. Neither contract refreshes
# the source timestamp just because GeoPresence polls the reading.
sub GP_Phone {
    my ($s,$cfg,$samples,$now,$mono)=@_;
    return unless GP_UsesSource($cfg->{sourceMode},'phone');
    my $p=$s->{phone};
    my $state_mode=($cfg->{phoneSignalMode}//'state') eq 'state';
    my (%valid,@positive);
    my $new_positive=0;
    for my $name (@{$cfg->{proxies}}) {
        my $v=$samples->{$name}//{};
        my $t=$v->{time};
        unless ($v->{healthy} && defined($t) && $t<=$now
            && ($state_mode || ($t>$s->{start} && $now-$t<=($v->{ttl}//0)))
            && ($v->{value}//'') =~ /\A(?:present|absent)\z/) {
            # Reconnection alone cannot restore an invalidated old sample.
            $p->{invalidated}{$name}=$now;
            next;
        }
        next if defined($p->{invalidated}{$name}) && $t<=$p->{invalidated}{$name};
        next if $t<($p->{samples}{$name}//0);
        delete $p->{invalidated}{$name};
        $valid{$name}=$v;
        if ($v->{value} eq 'present') {
            push @positive,$t;
            $new_positive=1 if $t>($p->{samples}{$name}//0);
        }
        $p->{samples}{$name}=$t;
    }
    if (@positive) {
        my $latest=(sort {$b<=>$a} @positive)[0];
        # The person may move between rooms, with several or temporarily no
        # sensors detecting them. Only a qualified absence or a long observation
        # gap ends continuity; a short handover is never a new arrival.
        my $long_gap=defined($p->{missing_since}) && $mono-$p->{missing_since}>=$cfg->{phone_absence_window};
        my $arrival=($p->{state} eq 'absent' || !$p->{ever_present} || $long_gap) ? 1:0;
        my $old_state=$p->{state};
        $p->{state}='present'; $p->{health}=$state_mode?'held':'fresh'; $p->{latest}=$latest; $p->{ever_present}=1;
        GP_ResetNegative($s,undef);
        delete $p->{missing_since};
        return unless $new_positive;
        return {kind=>'phone_snapshot',time=>$latest,received=>$now,generation=>$s->{generation}} if $state_mode && $latest<=$s->{start};
        return {kind=>'phone_present',time=>$latest,received=>$now,arrival=>$arrival,
            key=>'phone:'.$latest.':'.$old_state} if $s->{phase} ne 'home' || $s->{trip};
        return;
    }
    $p->{missing_since}//=$mono;
    # Each sensor covers part of the house. A negative quorum cannot establish
    # absence: every configured sensor must have a usable negative state.
    my $all_negative=@{$cfg->{proxies}} && !grep {!$valid{$_} || $valid{$_}{value} ne 'absent'} @{$cfg->{proxies}};
    if ($all_negative) {
        my @times=sort {$a<=>$b} map {$valid{$_}{time}} @{$cfg->{proxies}};
        # State mode uses the last observation establishing all-negative state.
        # Measurement mode needs every sensor to have measured after a boundary.
        my $observed=$state_mode ? $times[-1]:$times[0];
        if (defined($p->{negative_after}) && $observed<=$p->{negative_after}) {
            GP_ResetNegative($s,undef);
        } else {
            $p->{negative_since}//=$mono;
            $p->{negative_wall}//=$now;
            $p->{negative_first}//={map {$_=>$valid{$_}{time}} @{$cfg->{proxies}}};
            my $renewed=$state_mode || !grep {$valid{$_}{time}<=$p->{negative_first}{$_}} @{$cfg->{proxies}};
            if ($renewed && $mono-$p->{negative_since}>=$cfg->{phone_absence_window}) {
                $p->{state}='absent'; $p->{health}=$state_mode?'held':'fresh'; $p->{qualified}=1;
                return if $p->{negative_emitted};
                $p->{negative_emitted}=1;
                return {kind=>'phone_absent',time=>$observed,received=>$now,generation=>$s->{generation},
                    negative_generation=>$p->{negative_generation}//0,
                    negative_wall=>$p->{negative_wall},negative_since=>$p->{negative_since}};
            }
        }
    } else {
        GP_ResetNegative($s,undef);
    }
    if ($p->{state} eq 'present' && $mono-$p->{missing_since}<$cfg->{phone_absence_window}) {
        $p->{health}='handover';
    } else {
        $p->{state}='unknown' unless $p->{state} eq 'absent';
        $p->{health}='unknown';
    }
    return;
}

sub GP_TickState {
    my ($s,$cfg,$now,$mono)=@_;
    GP_CheckClock($s,$cfg,$now,$mono);
    if ($s->{phase} eq 'leaving' && $s->{trip} && defined($s->{trip}{leave_mono})
        && $mono-$s->{trip}{leave_mono}>=$cfg->{departure_grace}) {
        if (!GP_UsesSource($cfg->{sourceMode},'phone') || $s->{phone}{state} ne 'present') { $s->{phase}='away'; $s->{desired_status}='absent'; }
    }
    if (defined($s->{approach}) && $mono-$s->{approach}>=$cfg->{approach_timeout}) {
        delete @{$s}{qw(approach automotive motion motion_time)};
        $s->{phase}='away' if $s->{trip};
    }
    for my $name (keys %{$s->{zones}}) {
        my $z=$s->{zones}{$name};
        if ($now-$z->{time}>$cfg->{zone_display_max_age}) {
            $z->{entry}=0;
            $s->{location}='unknown' if ($s->{location}//'') eq $cfg->{zones}{$name}{label};
        }
    }
    return;
}

sub GP_HTTPConfigError {
    my ($c)=@_;
    my $port=GP_Attr($c->{NAME},'webhookPort','');
    return 'webhookPort must be an integer from 1024 to 65535'
        unless $port =~ /\A[0-9]{4,5}\z/ && $port>=1024 && $port<=65535;
    return 'webhookPath must be a simple path component'
        unless GP_Attr($c->{NAME},'webhookPath','geopresence') =~ /\A[a-zA-Z][a-zA-Z0-9_-]*\z/;
    my $address=GP_Attr($c->{NAME},'webhookBindAddress','127.0.0.1');
    return 'webhookBindAddress must be a concrete IPv4 address; no wildcard or hostname' unless GP_IPv4($address);
    return 'Network binding requires explicit webhookAllowedPeers'
        if $address !~ /\A127\./ && !length(GP_Attr($c->{NAME},'webhookAllowedPeers',''));
    return 'webhookAllowedPeers must list 1..16 distinct IPv4 addresses separated by commas'
        unless GP_PeerListValid(GP_Attr($c->{NAME},'webhookAllowedPeers','127.0.0.1'));
    return;
}

# This listener never enters FHEMWEB or FHEM's command parser. FHEMWEB dispatches
# XHR/cmd before FWEXT authentication, even on an otherwise restricted URL.
# Transient selectlist entries use the core's direct callbacks, not FHEM devices.
sub GP_CloseHTTPClient {
    my ($h)=@_;
    delete $selectlist{$h->{NAME}};
    my $c=$defs{$h->{OWNER}};
    delete $c->{helper}{gp_http}{clients}{$h->{NAME}} if $c && $c->{helper}{gp_http};
    close(delete $h->{CD}) if $h->{CD};
    delete $h->{FD};
}

sub GP_StopHTTP {
    my ($c)=@_;
    my $http=delete $c->{helper}{gp_http};
    delete $c->{helper}{gp_http_error};
    return unless $http;
    GP_CloseHTTPClient($_) for values %{$http->{clients}};
    my $server=$http->{server};
    delete $selectlist{$server->{NAME}};
    close(delete $server->{CD}) if $server->{CD};
    delete $server->{FD};
}

sub GP_OpenHTTP {
    my ($c,$port)=@_;
    my $address=GP_Attr($c->{NAME},'webhookBindAddress','127.0.0.1');
    my $peers=GP_Attr($c->{NAME},'webhookAllowedPeers','127.0.0.1');
    my $socket=IO::Socket::INET->new(LocalAddr=>$address,LocalPort=>$port,
        Proto=>'tcp',Listen=>16,ReuseAddr=>1,Blocking=>0);
    return "Cannot listen on $address:$port: $!" unless $socket;
    my $name='GeoPresenceHTTP:'.$c->{NAME};
    my $server={NAME=>$name,OWNER=>$c->{NAME},CD=>$socket,FD=>fileno($socket),directReadFn=>\&GP_AcceptHTTP};
    $c->{helper}{gp_http}={port=>$port,address=>$address,allowed_peers=>$peers,
        peers=>{map {$_=>1} GP_List($peers)},server=>$server,clients=>{}};
    $selectlist{$name}=$server;
    GP_Log($c,3,'listener_started',{reason=>"Listening on $address:$port"});
    return;
}

sub GP_EnsureHTTP {
    my ($c)=@_;
    if (my $error=GP_HTTPConfigError($c)) { GP_StopHTTP($c); return $error; }
    my $port=GP_Attr($c->{NAME},'webhookPort','');
    my $http=$c->{helper}{gp_http};
    GP_StopHTTP($c) if $http && ($http->{port} != $port
        || ($http->{address}//'') ne GP_Attr($c->{NAME},'webhookBindAddress','127.0.0.1')
        || ($http->{allowed_peers}//'') ne GP_Attr($c->{NAME},'webhookAllowedPeers','127.0.0.1'));
    unless ($c->{helper}{gp_http}) {
        my $error=GP_OpenHTTP($c,$port);
        if ($error) { $c->{helper}{gp_http_error}=$error; return $error; }
        delete $c->{helper}{gp_http_error};
    }
    for my $client (values %{$c->{helper}{gp_http}{clients}}) {
        GP_CloseHTTPClient($client) if GP_Mono()>=$client->{deadline};
    }
    return;
}

sub GP_AcceptHTTP {
    my ($server)=@_;
    my $c=$defs{$server->{OWNER}};
    return unless $c && $c->{helper}{gp_http};
    my $clients=$c->{helper}{gp_http}{clients};
    for (1..16) {
        my $socket=$server->{CD}->accept() or last;
        # Bound memory and work per callback; excess clients retry through Geofency.
        # Trust only the actual socket peer, never X-Forwarded-For/X-Real-IP.
        if (keys(%$clients)>=16 || !$c->{helper}{gp_http}{peers}{$socket->peerhost}) { close $socket; next; }
        $socket->blocking(0);
        my $name=$server->{NAME}.'.'.fileno($socket);
        my $h={NAME=>$name,OWNER=>$c->{NAME},CD=>$socket,FD=>fileno($socket),
            input=>'',deadline=>GP_Mono()+10,directReadFn=>\&GP_ReadHTTP};
        $clients->{$name}=$h;
        $selectlist{$name}=$h;
    }
}

# Parse exactly one bounded request, without decoding the URL or combining it
# with the body. No transfer coding, duplicate headers, folding or pipelining.
# An empty return means that more bytes are needed; errors carry an HTTP status.
sub GP_HTTPFrame {
    my ($input)=@_;
    my $end=index($input,"\r\n\r\n");
    return (undef,431,'Headers too large') if ($end<0 && length($input)>8192) || $end>8188;
    return if $end<0;
    my ($line,@lines)=split /\r\n/,substr($input,0,$end);
    return (undef,400,'Invalid request line') unless defined($line)
        && $line =~ m{\A([A-Z]+) ([\x21-\x7e]+) HTTP/1\.([01])\z};
    my ($method,$path,$version)=($1,$2,$3);
    my %headers;
    for my $header (@lines) {
        return (undef,400,'Invalid header') unless $header =~ /\A([A-Za-z0-9][A-Za-z0-9-]*):[ \t]*([\x20-\x7e\t]*)\z/;
        my ($key,$value)=(lc($1),$2);
        $value =~ s/[ \t]+\z//;
        return (undef,400,'Duplicate header') if exists $headers{$key};
        $headers{$key}=$value;
    }
    return (undef,400,'Host required') if $version eq '1' && !length($headers{host}//'');
    return (undef,400,'Transfer-Encoding unsupported') if exists $headers{'transfer-encoding'};
    return (undef,417,'Expect unsupported') if exists $headers{expect};
    return (undef,411,'Content-Length required') if $method eq 'POST' && !exists $headers{'content-length'};
    my $length=$headers{'content-length'}//0;
    return (undef,400,'Invalid Content-Length') unless $length =~ /\A[0-9]{1,6}\z/;
    return (undef,413,'Request too large') if $length>16384;
    my $received=length($input)-$end-4;
    return (undef,400,'Only one request per connection allowed') if $received>$length;
    return if $received<$length;
    return ({method=>$method,path=>$path,headers=>\%headers,body=>substr($input,$end+4)});
}

sub GP_HTTPResponse {
    my ($status,$text)=@_;
    my %labels=(200=>'OK',400=>'Bad Request',401=>'Unauthorized',403=>'Forbidden',404=>'Not Found',405=>'Method Not Allowed',
        411=>'Length Required',413=>'Content Too Large',415=>'Unsupported Media Type',417=>'Expectation Failed',
        422=>'Unprocessable Content',429=>'Too Many Requests',431=>'Request Header Fields Too Large',503=>'Service Unavailable');
    my $content=encode('UTF-8',$text."\n");
    return "HTTP/1.1 $status $labels{$status}\r\nContent-Type: text/plain; charset=utf-8\r\n"
        .'Content-Length: '.length($content)."\r\nCache-Control: no-store\r\nConnection: close\r\n"
        .($status==401 ? "WWW-Authenticate: Basic realm=\"GeoPresence\"\r\n" : '')
        .($status==405 ? "Allow: POST\r\n" : '')."\r\n".$content;
}

sub GP_ReadHTTP {
    my ($h)=@_;
    return GP_CloseHTTPClient($h) if GP_Mono()>=$h->{deadline};
    my $count=sysread($h->{CD},my $bytes,4096);
    return if !defined($count) && ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR);
    return GP_CloseHTTPClient($h) unless $count;
    $h->{input}.=$bytes;
    my ($request,$status,$text)=GP_HTTPFrame($h->{input});
    if ($request) {
        ($status,$text)=GP_HTTP($defs{$h->{OWNER}},@$request{qw(method path headers body)});
    } elsif ($status) {
        GP_Log($defs{$h->{OWNER}},2,'http_frame_rejected',{status=>$status,reason=>$text});
    }
    return unless $status;
    delete $h->{input};
    delete $h->{directReadFn};
    $h->{output}=GP_HTTPResponse($status,$text);
    $h->{directWriteFn}=\&GP_WriteHTTP;
}

sub GP_WriteHTTP {
    my ($h)=@_;
    return GP_CloseHTTPClient($h) if GP_Mono()>=$h->{deadline};
    local $SIG{PIPE}='IGNORE';
    my $count=syswrite($h->{CD},$h->{output});
    return if !defined($count) && ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR);
    return GP_CloseHTTPClient($h) unless $count;
    substr($h->{output},0,$count,'');
    GP_CloseHTTPClient($h) unless length $h->{output};
}

sub GP_ClearCheckpoint {
    my ($r,$reason)=@_;
    my $d=$defs{$r} or return;
    my $value=$GP_CHECKPOINT_JSON->encode({version=>1,status=>'none',reason=>$reason});
    return if GP_Read($r,'gp_trip_checkpoint','') eq $value;
    setReadingsVal($d,'gp_trip_checkpoint',$value,POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now())));
}

sub GP_ResumeRevision {
    my ($c,$r,$cfg)=@_;
    # Geometry, rules, adapters and source contract are part of the cfg hash.
    # Bind identities and authentication too, without persisting credentials.
    return $cfg->{resume_revision} if defined $cfg->{resume_revision};
    my $revision=GP_ConfigRevision($cfg);
    my (undef,$auth)=GP_Auth($r);
    return $cfg->{resume_revision}=sha256_hex($GP_CHECKPOINT_JSON->encode({
        config=>$revision,controller=>$c->{NAME},resident=>$r,
        device=>lc(GP_Attr($r,'deviceId','')),user=>lc(GP_Attr($r,'webhookUser','')),
        auth=>sha256_hex($auth//''),roommate=>$cfg->{roommate}}));
}

sub GP_Checkpoint {
    my ($c,$r,$cfg,$s)=@_;
    my $rt=$c->{helper}{gp};
    # Invalidated evidence must also reach the state file while the listener is
    # down or a contradiction blocks outputs. Persistence is not an actuator.
    return unless $rt && GP_EffectiveMode($c,$r,0) eq 'active'
        && $rt->{prod}{$r} && $rt->{prod}{$r}==$s;
    # Idle ticks do not serialize the configuration or journey again. Every
    # relevant mutation records a trace; quiet reads must remain cheap.
    return if defined($s->{checkpoint_sequence}) && $s->{checkpoint_sequence}==($s->{trace_sequence}//0)
        && ($s->{checkpoint_value}//'') eq GP_Read($r,'gp_trip_checkpoint','');
    my $t=$s->{trip};
    if ($t && $t->{armed} && !$s->{conflict} && GP_UsesSource($cfg->{sourceMode},'geo')
        && $cfg->{geometry_ready} && $s->{phase} =~ /\A(?:away|leaving|returning)\z/) {
        my $checkpoint={version=>1,status=>'qualified',saved_at=>GP_Now(),
            revision=>GP_ResumeRevision($c,$r,$cfg),
            trip=>{map {$_=>$t->{$_}} grep {exists $t->{$_}} qw(id start home_exit scope armed away_time away_reason actions exits)},
            state=>{map {$_=>$s->{$_}} grep {exists $s->{$_}}
                qw(location position_time boundary zones members zone_visits group_visits notify_seen notify_order notify_last motion motion_time automotive)}};
        my $value=eval {$GP_CHECKPOINT_JSON->encode($checkpoint)};
        if (defined($value) && length($value)<=65536) {
            setReadingsVal($defs{$r},'gp_trip_checkpoint',$value,
                POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now())));
        } else {
            GP_ClearCheckpoint($r,'Qualified trip checkpoint exceeds storage limit');
            GP_Trace($s,GP_Now(),'qualified trip could not be checkpointed',{source=>'checkpoint'});
        }
    } else { GP_ClearCheckpoint($r,'No unfinished qualified trip'); }
    $s->{checkpoint_sequence}=$s->{trace_sequence}//0;
    $s->{checkpoint_value}=GP_Read($r,'gp_trip_checkpoint','');
}

sub GP_ResumeTrip {
    my ($c,$r,$cfg,$s)=@_;
    my $raw=GP_Read($r,'gp_trip_checkpoint','');
    $s->{resume}={status=>'none',reason=>'No saved qualified trip'};
    return unless length($raw);
    my ($checkpoint,$trip,$state);
    my ($now,$mono)=(GP_Now(),GP_Mono());
    my $error;
    {
        local $@;
        my $ok=eval {
            die "checkpoint too large\n" if length($raw)>65536;
            $checkpoint=$GP_CHECKPOINT_JSON->decode($raw);
            die "invalid checkpoint structure\n" unless ref($checkpoint) eq 'HASH'
                && !ref($checkpoint->{version}) && ($checkpoint->{version}//'') eq '1'
                && !ref($checkpoint->{status}) && ($checkpoint->{status}//'') =~ /\A(?:qualified|none)\z/;
            if ($checkpoint->{status} eq 'qualified') {
                die "resident is not active\n" unless GP_EffectiveMode($c,$r,0) eq 'active';
                die "configuration or identity changed\n" unless $cfg->{geometry_ready}
                    && GP_UsesSource($cfg->{sourceMode},'geo')
                    && ($checkpoint->{revision}//'') eq GP_ResumeRevision($c,$r,$cfg);
                $trip=$checkpoint->{trip}; $state=$checkpoint->{state};
                die "invalid trip structure\n" unless ref($trip) eq 'HASH' && ref($state) eq 'HASH'
                    && !ref($trip->{armed}) && ($trip->{armed}//'') eq '1'
                    && !ref($trip->{scope}) && ($trip->{scope}//'') =~ /\A(?:local|remote)\z/
                    && defined($trip->{id}) && !ref($trip->{id}) && length($trip->{id})<=256
                    && $trip->{id} =~ /\A[A-Za-z0-9_.:\-]+\z/;
                my %trip_keys=map {$_=>1} qw(id start home_exit scope armed away_time away_reason actions exits);
                my %state_keys=map {$_=>1} qw(location position_time boundary zones members zone_visits group_visits notify_seen notify_order notify_last motion motion_time automotive);
                die "unsupported checkpoint fields\n" if grep {!$trip_keys{$_}} keys %$trip;
                die "unsupported checkpoint fields\n" if grep {!$state_keys{$_}} keys %$state;
                die "invalid departure reason\n" if exists($trip->{away_reason})
                    && (ref($trip->{away_reason}) || length($trip->{away_reason}//'')>512);
                for my $time ($trip->{start},$trip->{away_time},$checkpoint->{saved_at}) {
                    die "invalid trip timestamp\n" unless GP_Number($time) && $time>0 && $time<=$now+$cfg->{future_tolerance};
                }
                die "inconsistent departure timestamps\n" if $trip->{away_time}<$trip->{start}
                    || $checkpoint->{saved_at}+$cfg->{future_tolerance}<$trip->{away_time};
                die "saved departure expired\n" if $now-$trip->{away_time}>$cfg->{trip_resume_max_age};
                for my $time (map {$trip->{$_}} grep {defined $trip->{$_}} qw(home_exit)) {
                    die "invalid Home exit\n" unless GP_Number($time) && $time>=$trip->{start}
                        && $time<=$checkpoint->{saved_at}+$cfg->{future_tolerance};
                }
                for my $key (qw(position_time boundary motion_time automotive)) {
                    next unless exists $state->{$key};
                    die "invalid observation timestamp\n" unless GP_Number($state->{$key}) && $state->{$key}>=0
                        && $state->{$key}<=$checkpoint->{saved_at}+$cfg->{future_tolerance};
                }
                die "invalid saved movement\n" if exists($state->{motion})
                    && ($state->{motion}//'') !~ /\A(?:unknown|stationary|walking|running|cycling|automotive)\z/;
                die "invalid saved location\n" if exists($state->{location})
                    && (ref($state->{location}) || length($state->{location}//'')>512);
                for my $key (qw(actions exits)) {
                    die "invalid trip history\n" if exists($trip->{$key}) && ref($trip->{$key}) ne 'HASH';
                }
                for my $key (keys %{$trip->{actions}//{}}) {
                    die "invalid consumed action\n" unless length($key)<=512
                        && GP_Number($trip->{actions}{$key}) && $trip->{actions}{$key}>0;
                }
                for my $ref (keys %{$trip->{exits}//{}}) {
                    my $time=$trip->{exits}{$ref};
                    die "invalid prior exit\n" unless ($ref =~ /\Alocation:(.+)\z/ && $cfg->{zones}{$1}
                        || $ref =~ /\Agroup:(.+)\z/ && $cfg->{groups}{$1})
                        && GP_Number($time) && $time>=$trip->{start}
                        && $time<=$checkpoint->{saved_at}+$cfg->{future_tolerance};
                }
                for my $key (qw(zones members)) {
                    die "invalid saved membership\n" if exists($state->{$key}) && ref($state->{$key}) ne 'HASH';
                    for my $name (keys %{$state->{$key}//{}}) {
                        my $v=$state->{$key}{$name};
                        die "invalid saved membership\n" unless $cfg->{zones}{$name} && ref($v) eq 'HASH'
                            && ($v->{entry}//'') =~ /\A[01]\z/ && GP_Number($v->{time}) && $v->{time}>0
                            && $v->{time}<=$checkpoint->{saved_at}+$cfg->{future_tolerance};
                    }
                }
                for my $key (qw(zone_visits group_visits notify_seen notify_last)) {
                    die "invalid saved counters\n" if exists($state->{$key}) && ref($state->{$key}) ne 'HASH';
                    for my $v (values %{$state->{$key}//{}}) {
                        die "invalid saved counter\n" unless GP_Number($v) && $v>=0;
                    }
                }
                die "invalid notification history\n" if exists($state->{notify_order})
                    && (ref($state->{notify_order}) ne 'ARRAY' || @{$state->{notify_order}}>2000
                        || grep {!defined($_) || ref($_) || length($_)>512} @{$state->{notify_order}});
                my $rrtime=GP_ReadingTime($cfg->{roommate},'state');
                die "a later ROOMMATE Home state superseded the departure\n" if defined($rrtime)
                    && $rrtime>=int($trip->{away_time}) && GP_Read($cfg->{roommate},'state','') =~ /\A(?:home|gotosleep|asleep|awoken)\z/;
                if (GP_UsesSource($cfg->{sourceMode},'phone')) {
                    my $samples=GP_PhoneSamples($cfg,$now);
                    die "a later local presence superseded the departure\n" if grep {
                        my $v=$samples->{$_}; $v->{healthy} && ($v->{value}//'') eq 'present'
                            && defined($v->{time}) && $v->{time}>=int($trip->{away_time}) && $v->{time}<=$now
                    } @{$cfg->{proxies}};
                }
            }
            1;
        };
        $error=$@ unless $ok;
    }
    if ($error) {
        $error =~ s/\s+\z//;
        $s->{resume}={status=>'rejected',reason=>$error};
        GP_ClearCheckpoint($r,'Restart recovery rejected: '.$error);
        GP_Trace($s,$now,'saved trip rejected: '.$error,{source=>'restart'});
        return;
    }
    return unless $checkpoint->{status} eq 'qualified';
    # Monotonic origins belong to the NEW process. Carry absolute evidence
    # times across reboot; never reuse a pending dwell timer or old queue.
    $s->{$_}=$state->{$_} for keys %$state;
    $s->{zones}{$_}{role}=$cfg->{zones}{$_}{role} for keys %{$s->{zones}};
    $s->{trip}=$trip;
    $s->{trip}{away_mono}=$mono-($now-$trip->{away_time});
    $s->{trip}{leave_mono}=$mono-($now-$trip->{home_exit}) if defined $trip->{home_exit};
    $s->{phase}='away';
    $s->{resume_event_floor}=$s->{start};
    $s->{resume}={status=>'restored',restored_at=>$now,saved_at=>$checkpoint->{saved_at},reason=>'Qualified unfinished trip restored'};
    GP_Trace($s,$now,'qualified unfinished trip restored; waiting for a new return',{source=>'restart'});
}

sub GP_State {
    my ($c,$r,$debug,$cfg)=@_;
    my $rt=$c->{helper}{gp};
    my $pool=$debug ? 'debug':'prod';
    unless ($rt->{$pool}{$r}) {
        my $s=GP_NewState($rt->{resident_start}{$r}//$rt->{start},$rt->{resident_mono}{$r}//$rt->{mono},
            $rt->{epoch}.':'.$pool.':'.$r.':'.($rt->{resident_generation}{$r}//0),GP_Attr($r,'sourceMode','geofency_phone'));
        unless ($debug) {
            $s->{restored}={map {$_=>GP_Read($r,$_,'unknown')} qw(gp_phase gp_location gp_trip_id gp_door_result gp_garage_result)};
            for my $result (qw(door_result garage_result)) {
                $s->{$result}='uncertain' if $s->{restored}{'gp_'.$result} =~ /\A(?:pending|dispatch_started|shared)\z/;
            }
        }
        $rt->{$pool}{$r}=$s;
        GP_ResumeTrip($c,$r,$cfg//GP_Config($c,$r,0),$s) if !$debug && delete $rt->{resume_pending}{$r};
    }
    return $rt->{$pool}{$r};
}

sub GP_Normalize {
    my ($c,$r,$cfg,$p,$now,$learning)=@_;
    return (undef,'Invalid device identifier') unless GP_Id($p->{device});
    my $device=lc($p->{device});
    my $expected=lc GP_Attr($r,'deviceId','');
    if ($learning) {
        my $learned=GP_Learned($c,$r);
        return (undef,'Learning unavailable; use set resident mode learning') unless $learned;
        $expected=$learned->{device};
        return (undef,'device does not match authenticated resident') if length($expected) && $device ne $expected;
    } else {
        return (undef,'device does not match authenticated resident') unless $device eq $expected;
    }
    return (undef,'Invalid entry') unless ($p->{entry}//'') =~ /\A[01]\z/;
    my ($time,$canonical)=GP_ParseTime($p->{date});
    return (undef,'Invalid original event date') unless defined $time;
    return (undef,'Invalid location id') unless GP_Id($p->{id});
    my @zones=grep {lc($p->{id}//'') eq $_->{id}} values %{$cfg->{zones}};
    return (undef,'Unknown location id; use set resident mode learning and send an isTest=true webhook') unless @zones==1 || $learning;
    my $z=$zones[0];
    return (undef,'Invalid location name') if defined($p->{name}) && length($p->{name})>200;
    return (undef,'Missing or invalid zone geometry') unless GP_HasGeometry({lat=>$p->{latitude},lon=>$p->{longitude},radius=>$p->{radius}});
    my $position={lat=>0+$p->{latitude},lon=>0+$p->{longitude}};
    my $motion=lc($p->{motion}//'unknown');
    my %motion=(automotive=>'automotive',walking=>'walking',running=>'running',cycling=>'cycling',stationary=>'stationary');
    $motion=$motion{$motion}//'unknown';
    my $current;
    if (GP_Number($p->{currentLatitude}) && abs($p->{currentLatitude})<=90
        && GP_Number($p->{currentLongitude}) && abs($p->{currentLongitude})<=180) {
        $current={lat=>0+$p->{currentLatitude},lon=>0+$p->{currentLongitude}};
    }
    return ({kind=>'geo',device=>$device,zone=>$z ? $z->{name}:undef,zone_id=>lc($p->{id}),zone_name=>$p->{name}//'',
        geometry=>{%$position,radius=>0+$p->{radius}},entry=>0+$p->{entry},time=>$time,received=>$now,motion=>$motion,
        key=>join('|',$device,lc($p->{id}),$p->{entry},$canonical),
        zone_position=>$position,current_position=>$current,revision=>GP_ConfigRevision($cfg)},undef);
}

sub GP_Learned {
    my ($c,$r)=@_;
    my $learned=$c->{helper}{gp}{learned}{$r};
    # Expiry limits incoming learning events, not the time to copy manual commands.
    return unless $learned;
    my $configured=lc GP_Attr($r,'deviceId','');
    return unless $learned->{unbound}
        ? !length($configured)
        : $learned->{device} eq $configured;
    return $learned;
}

sub GP_LearningDeviceConflict {
    my ($c,$r,$device)=@_;
    return 'Invalid device identifier' unless GP_Id($device);
    for my $other (GP_Residents($c)) {
        next if $other eq $r;
        next unless GP_UsesSource(GP_Attr($other,'sourceMode','geofency_phone'),'geo');
        return "Device identifier already assigned to $other" if lc GP_Attr($other,'deviceId','') eq $device;
        my $candidate=GP_Learned($c,$other);
        return "Device identifier already being learned for $other"
            if $candidate && $candidate->{unbound} && $candidate->{device} eq $device;
    }
    return;
}

sub GP_CaptureLocation {
    my ($c,$r,$e,$cfg,$now)=@_;
    my $learned=GP_Learned($c,$r) or return (503,'Learning expired; start again');
    return (503,'Learning expired; start again') unless $c->{helper}{gp}{learning}{$r}
        && GP_Mono()<=$learned->{until};
    return (422,'Learning requires a fresh test event') unless GP_Fresh($cfg,$e,$now) && $e->{time}>=$learned->{start}-1;
    my $conflict=GP_LearningDeviceConflict($c,$r,$e->{device});
    return (422,$conflict) if $conflict;
    my $old=$learned->{zones}{$e->{zone_id}};
    return (422,'Older learning observation ignored') if $old && $e->{time}<$old->{time};
    return (422,'Conflicting learning observation; send a newer test event') if $old && $e->{time}==$old->{time}
        && $GP_JSON->encode($old->{geometry}) ne $GP_JSON->encode($e->{geometry});
    return (429,'At most 32 locations per learning session') unless $old || keys(%{$learned->{zones}})<32;
    # Pin the candidate only AFTER validating the complete fresh observation.
    # HTTP reception never writes the deviceId attribute or calls CommandAttr.
    if ($learned->{unbound} && !length($learned->{device})) {
        $learned->{device}=$e->{device};
        GP_Log($c,3,'learning_device_captured',{resident=>$r,mode=>'learning',reason=>'Device identifier captured; use learnConfirm to confirm'});
    }
    $learned->{zones}{$e->{zone_id}}={id=>$e->{zone_id},name=>$e->{zone_name},geometry=>$e->{geometry},time=>$e->{time},
        number=>$old ? $old->{number}:1+keys(%{$learned->{zones}})};
    return (200,'OK learning captured; no actions');
}

sub GP_BeginLearning {
    my ($c,$r)=@_;
    return 'Enable the controller with set '.$c->{NAME}.' mode debug or active first' if GP_Mode($c->{NAME}) eq 'disabled';
    return 'Learning requires a Geofency source' unless GP_UsesSource(GP_Attr($r,'sourceMode','geofency_phone'),'geo');
    my $device=lc GP_Attr($r,'deviceId','');
    return 'Invalid configured deviceId; remove or correct it before learning' if length($device) && !GP_Id($device);
    my $user=GP_Attr($r,'webhookUser','');
    return 'Learning requires a unique webhookUser and a stored webhookPassword' unless GP_Id($user)
        && 1==grep {GP_Attr($_,'webhookUser','') eq $user
            && GP_UsesSource(GP_Attr($_,'sourceMode','geofency_phone'),'geo')} GP_Residents($c);
    my ($error,$auth)=GP_Auth($r);
    return 'Learning requires a stored webhookPassword' if $error || ($auth//'') !~ /\A[a-f0-9]{32}:[a-f0-9]{64}\z/;
    my $conflict=length($device) ? GP_LearningDeviceConflict($c,$r,$device) : undef;
    return $conflict if $conflict;
    GP_ResetResident($c,$r);
    my $rt=$c->{helper}{gp};
    $rt->{learned}{$r}={device=>$device,unbound=>length($device)?0:1,confirmed=>0,
        start=>GP_Now(),until=>GP_Mono()+900,zones=>{}};
    $rt->{learning}{$r}=1;
    GP_StoreMode($defs{$r},'learning');
    GP_UpdateModes($c);
    GP_Log($c,3,'learning_started',{resident=>$r,mode=>'learning',reason=>'15 minute window for isTest=true webhooks; no journeys or actions'});
    return 'Learning for 15 minutes; send Geofency entry/exit tests to the normal webhook URL; use set '.$r.' learnConfirm afterwards';
}

sub GP_ExpireLearning {
    my ($c,$r)=@_;
    return unless GP_Mode($r) eq 'learning';
    my $rt=$c->{helper}{gp}; my $learned=GP_Learned($c,$r);
    return if $learned && $rt->{learning}{$r} && GP_Mono()<=$learned->{until};
    GP_ResetResident($c,$r,'capture');
    $learned->{expired}=1 if $learned;
    GP_UpdateModes($c);
    GP_Log($c,3,'learning_expired',{resident=>$r,mode=>'learning',reason=>'Reception stopped; resident disabled; captured data awaits explicit learnConfirm'});
}

sub GP_LearnConfirm {
    my ($c,$r)=@_;
    return 'Controller unavailable' unless $c && $c->{helper}{gp};
    my $rt=$c->{helper}{gp}; my $learned=GP_Learned($c,$r);
    return 'No captured learning data; use set '.$r.' mode learning first' unless $learned;
    return 'Learning already confirmed; resident mode unchanged' if $learned->{confirmed};
    return 'Learning confirmation requires learning or disabled mode' unless GP_Mode($r) =~ /\A(?:learning|disabled)\z/;
    return 'No device or location captured; send a fresh Geofency test before confirming'
        unless length($learned->{device}) && keys %{$learned->{zones}};
    my $conflict=GP_LearningDeviceConflict($c,$r,$learned->{device});
    return $conflict if $conflict;
    # Close reception before committing an ordinary FHEM attribute. Any callbacks
    # may reconfigure the resident: never resurrect their superseded setup state.
    GP_ResetResident($c,$r,'capture');
    GP_UpdateModes($c);
    if ($learned->{unbound}) {
        my $resident=$defs{$r}; my $generation=$rt->{resident_generation}{$r};
        my $error=CommandAttr($c->{CL},"$r deviceId $learned->{device}");
        return "Cannot confirm device identifier: $error" if $error;
        return 'Device confirmation interrupted by a configuration change; check deviceId and restart learning'
            unless ($defs{$r}//0)==$resident && GP_TimerCurrent($c,$rt)
                && GP_Attr($r,'deviceId','') eq $learned->{device} && GP_Mode($r) eq 'disabled'
                && $rt->{resident_generation}{$r}==$generation+1;
        delete $learned->{unbound};
    }
    $learned->{confirmed}=1;
    $rt->{learned}{$r}=$learned;
    GP_Log($c,3,'learning_confirmed',{resident=>$r,mode=>'learning',reason=>'Device identifier and captured locations confirmed; resident remains disabled'});
    return 'Learning confirmed; deviceId '.$learned->{device}.' configured; resident disabled; create locations and applyGeometry before testing';
}

sub GP_SetMode {
    my ($d,$mode)=@_;
    my $kind=$d->{SUBTYPE}//''; my $name=$d->{NAME}; my $c=GP_Controller($d);
    return 'mode is available on controllers and residents only' unless $kind eq 'controller' || $kind eq 'resident';
    return 'Controller unavailable' unless $c && $c->{helper}{gp};
    return 'Choose active, debug, disabled'.($kind eq 'resident'?' or learning':'')
        unless defined($mode) && ($mode =~ /\A(?:active|debug|disabled)\z/ || ($kind eq 'resident' && $mode eq 'learning'));
    GP_ExpireLearning($c,$name) if $kind eq 'resident';
    if (GP_Mode($name) eq $mode) {
        # An expired window leaves a reviewable candidate while disabled. An
        # explicit disabled command is also the operator's cancellation path.
        if ($kind eq 'resident' && $mode eq 'disabled' && $c->{helper}{gp}{learned}{$name} && !$c->{helper}{gp}{learned}{$name}{confirmed}) {
            GP_ResetResident($c,$name); GP_UpdateModes($c);
        }
        return;
    }
    return GP_BeginLearning($c,$name) if $mode eq 'learning';
    if ($mode eq 'active') {
        # Validate the proposed effective configuration without committing state.
        local $d->{READINGS}{mode}{VAL}=$mode;
        my @errors=GP_Validate($c,$kind eq 'resident' ? $name:undef,1);
        return 'Cannot activate: '.join('; ',@errors) if @errors;
    }
    if ($kind eq 'controller') {
        # Mode changes never rebind the listening socket. Hardware feedback for
        # already dispatched requests remains observed across every transition.
        GP_ResetResident($c,$_,$mode eq 'disabled'?'':'learning') for GP_Residents($c);
    } else { GP_ResetResident($c,$name); }
    GP_StoreMode($d,$mode);
    $d->{STATE}=$mode if $kind eq 'controller';
    GP_UpdateModes($c);
    GP_Log($c,3,'mode_changed',{($kind eq 'resident'?(resident=>$name):()),mode=>$mode,
        reason=>'Mode changed; previous journeys and opening permissions revoked'});
    return;
}

# Called only by the dedicated listener; there is no FHEMWEB command dispatcher.
sub GP_HTTP {
    my ($c,$method,$path,$headers,$body)=@_;
    my $diag={route=>'unknown'};
    if ($c) {
        my $base='/fhem/'.GP_Attr($c->{NAME},'webhookPath','geopresence');
        $diag->{route}=$path eq $base ? 'webhook' : 'unknown';
    }
    my ($status,$text)=GP_HandleHTTP($c,$method,$path,$headers,$body,$diag);
    my $level=$status>=400 && $status!=404 && $status!=405 ? 2:4;
    GP_Log($c,$level,'http',{%$diag,status=>$status,reason=>$text});
    return ($status,$text);
}

sub GP_HandleHTTP {
    my ($c,$method,$path,$headers,$body,$diag)=@_;
    return (404,'Unknown webhook') unless $c;
    my $base='/fhem/'.GP_Attr($c->{NAME},'webhookPath','geopresence');
    return (404,'Unknown webhook') unless $path eq $base;
    return (405,'POST required') unless $method eq 'POST';
    return (415,'application/x-www-form-urlencoded required') unless ($headers->{'content-type'}//'') =~ m{\Aapplication/x-www-form-urlencoded(?:\s*;|\z)}i;
    return (413,'Request too large') if length($body)>16384;
    my $rt=$c->{helper}{gp};
    return (503,'Initializing') unless $rt && $rt->{ready};
    my $now=GP_Now();
    if (!defined($rt->{rate_start}) || $now-$rt->{rate_start}>=60) { $rt->{rate_start}=$now; $rt->{rate_count}=0; }
    return (429,'Rate limit') if ++$rt->{rate_count}>120;
    my $auth=$headers->{authorization}//'';
    return (401,'Authentication required') unless $auth =~ /\ABasic ([A-Za-z0-9+\/=]+)\z/;
    my ($user,$password)=split /:/,decode_base64($1),2;
    return (401,'Authentication required') unless defined($password) && length($password)<=256;
    my @res=grep {GP_Attr($_,'webhookUser','') eq $user
        && GP_UsesSource(GP_Attr($_,'sourceMode','geofency_phone'),'geo')} GP_Residents($c);
    return (401,'Authentication required') unless @res==1;
    my $r=$res[0];
    my ($err,$stored)=GP_Auth($r);
    return (401,'Authentication required') if $err || !defined($stored) || $stored !~ /\A([a-f0-9]{32}):([a-f0-9]{64})\z/;
    my ($salt,$expected)=($1,$2);
    my $actual=sha256_hex($salt.':'.$password);
    my $diff=0; $diff|=ord(substr($actual,$_,1))^ord(substr($expected,$_,1)) for 0..63;
    return (401,'Authentication required') if $diff;
    GP_ExpireLearning($c,$r);
    my $mode=GP_EffectiveMode($c,$r,0);
    @{$diag}{qw(resident mode)}=($r,$mode);
    return (503,'Resident disabled') if $mode eq 'disabled';
    my ($p,$parse_error,$form_info)=GP_DecodeForm($body);
    return (400,$parse_error) if $parse_error;
    $diag->{ignored_multiline}=$form_info->{ignored_multiline} if length($form_info->{ignored_multiline}//'');
    return (400,'FHEM control fields are not webhook data') if grep {
        /\A(?:cmd(?:\..*)?|xhr|jsonp|fwcsrf|inform|asyncoutput)\z/i
    } keys %$p;
    # A test flag can only REMOVE productive authority. Authenticate first,
    # reject malformed markers, then choose the isolated pool before any state,
    # geometry or permission is read or changed for this observation.
    return (400,'Use the case-sensitive field name isTest') if grep {lc($_) eq 'istest' && $_ ne 'isTest'} keys %$p;
    return (400,'isTest must be true, false, 1 or 0') if exists($p->{isTest}) && $p->{isTest} !~ /\A(?:true|false|1|0)\z/;
    my $test=($p->{isTest}//'false') =~ /\A(?:true|1)\z/ ? 1:0;
    $mode=GP_EffectiveMode($c,$r,$test);
    @{$diag}{qw(mode isTest)}=($mode,$test);
    my $cfg=GP_Config($c,$r,$mode eq 'debug');
    return (403,'Resident has no Geofency source') unless GP_UsesSource($cfg->{sourceMode},'geo');
    my $learning=$mode eq 'learning' && $rt->{learning}{$r};
    # During explicit enrollment, spontaneous real observations are acknowledged
    # but do not enroll a phone/zone or enter either trip state. Geofency need not
    # retry these intentionally ignored observations after setup has finished.
    return (200,'OK ignored during learning; isTest=true required; no actions') if $learning && !$test;
    my ($e,$invalid)=GP_Normalize($c,$r,$cfg,$p,$now,$learning);
    @{$diag}{qw(zone entry observed)}=($e->{zone},$e->{entry},$e->{time}) if $e;
    if ($learning) {
        return (422,$invalid) if $invalid;
        return GP_CaptureLocation($c,$r,$e,$cfg,$now);
    }
    my @errors=GP_Validate($c,$r,$mode eq 'active',$cfg);
    return (503,'Configuration invalid; see get validate') if @errors;
    my $s=GP_State($c,$r,$mode eq 'debug');
    if ($invalid) {
        GP_Trace($s,$now,$invalid);
        return (422,$invalid);
    }
    return (503,'Queue full') if @{$rt->{queue}}>=128;
    push @{$rt->{queue}}, {resident=>$r,debug=>$mode eq 'debug'?1:0,event=>$e,
        due=>GP_Mono()+$cfg->{reorder_window},epoch=>$rt->{epoch}};
    return (200,$mode eq 'debug' ? 'OK debug accepted; no actions' : 'OK accepted in current FHEM session');
}

sub GP_ActorFeedbackSources {
    my ($intent)=@_;
    my $p=$intent->{params};
    return $intent->{kind} eq 'door_open' ? ([$p->{feedbackDevice},'pulse_state'])
        : ([$p->{stateDevice},'state'],[$p->{upperContact},'state'],[$p->{lowerContact},'state']);
}

sub GP_ReadingFingerprint {
    my ($device,$reading)=@_;
    return (GP_Reading($device,$reading)->{TIME}//'')."\0".GP_Read($device,$reading,'');
}

sub GP_ActorReadingFresh {
    my ($actor,$device,$reading)=@_;
    my $time=GP_ReadingTime($device,$reading);
    # TIME represents a whole second, not the beginning of the actual update.
    # Accept the dispatch second only with evidence of an update after reserving
    # this actor. Rounding alone could reuse a preceding pulse's confirmation.
    return 0 unless defined($time) && $time>=int($actor->{start});
    my $watch=$actor->{feedback}{$device}{$reading} or return 0;
    my $current=GP_ReadingFingerprint($device,$reading);
    return $current ne $watch->{before} || $current eq ($watch->{observed}//'');
}

sub GP_UpdateNotifyDevices {
    my ($c)=@_;
    my %devices=(global=>1);
    $devices{$defs{$_}{ROOMMATE}}=1 for GP_Residents($c);
    for my $actor (values %{$c->{helper}{gp}{actors}}) {
        $devices{$_}=1 for keys %{$actor->{feedback}//{}};
    }
    my $notify=join(',',sort keys %devices);
    setNotifyDev($c,$notify) if ($c->{NOTIFYDEV}//'') ne $notify;
}

sub GP_ActorPositionUsable {
    my ($device,$reading,$start,$mode)=@_;
    my $d=$defs{$device} or return 0;
    my $time=GP_ReadingTime($device,$reading);
    return 0 unless defined($time) && $time<=GP_Now();
    return 0 if GP_Attr($device,'disable',0) || (($d->{helper}//{})->{DISABLED})
        || ($d->{STATE}//'') =~ /\A(?:disconnected|disabled|error|timeout|unreachable|dead)(?:\b|:)/i
        || GP_Read($device,'Activity','') eq 'dead';
    if (defined(my $io=$d->{IODev})) {
        $io=$defs{$io} unless ref($io);
        return 0 unless ref($io) eq 'HASH' && defined($io->{NAME})
            && ($defs{$io->{NAME}}//0)==$io;
        return 0 if GP_Attr($io->{NAME},'disable',0) || (($io->{helper}//{})->{DISABLED})
            || ($io->{STATE}//'') =~ /\A(?:disconnected|disabled|error|timeout|unreachable|dead)(?:\b|:)/i;
    }
    return $mode eq 'measurement' ? $time>$start : 1;
}

sub GP_ActorView {
    my ($intent,$start,$actor)=@_;
    my $p=$intent->{params};
    my @needed=$intent->{kind} eq 'door_open' ? ([$p->{contact},'state'])
        : ([$p->{stateDevice},'state'],[$p->{upperContact},'state'],[$p->{lowerContact},'state']);
    for my $ref (@needed) {
        if ($actor) {
            return 'unknown' unless GP_ActorReadingFresh($actor,@$ref);
        } else {
            return 'unknown' unless GP_ActorPositionUsable(@$ref,$start,$p->{positionSignalMode}//'state');
        }
    }
    if ($intent->{kind} eq 'door_open') {
        my $contact=GP_Read($p->{contact},'state','unknown');
        return 'open' if $contact eq 'open';
        return 'unknown' unless $contact eq 'closed';
        return 'opening' if GP_Read($p->{feedbackDevice},'pulse_state','unknown') eq 'pending';
        return 'closed';
    }
    my $up=GP_Read($p->{upperContact},'state','unknown');
    my $down=GP_Read($p->{lowerContact},'state','unknown');
    my $state=GP_Read($p->{stateDevice},'state','unknown');
    return 'closed' if $up eq 'open' && $down eq 'closed' && $state eq 'off';
    return 'open' if $up eq 'closed' && $down eq 'open' && $state eq 'on';
    return 'opening' if $up eq 'open' && $down eq 'open' && $state eq 'movup';
    return 'closing' if $up eq 'open' && $down eq 'open' && $state eq 'movdown';
    return 'unknown';
}

sub GP_ActorResult {
    my ($actor)=@_;
    return $actor->{completion} if defined($actor->{completion});
    my $intent=$actor->{intent};
    if ($intent->{kind} eq 'door_open') {
        my $device=$intent->{params}{feedbackDevice};
        my $value=GP_Read($device,'pulse_state','');
        return $value if GP_ActorReadingFresh($actor,$device,'pulse_state')
            && $value =~ /\A(?:confirmed|failed|cancelled)\z/;
    } else {
        return 'confirmed' if GP_ActorView($intent,$actor->{start},$actor) eq 'open';
    }
    return;
}

sub GP_CanOutput {
    my ($c,$r,$s)=@_;
    my $rt=$c->{helper}{gp};
    return $rt && $rt->{ready} && GP_EffectiveMode($c,$r,0) eq 'active'
        && $rt->{prod}{$r} && $rt->{prod}{$r}==$s && !$s->{conflict};
}

sub GP_Dispatch {
    my ($c,$r,$cfg,$s,$debug,$now,$mono)=@_;
    # Consuming the trip is checkpointed BEFORE any synchronous device/logging
    # callback can save state or reload the module during an opening request.
    GP_Checkpoint($c,$r,$cfg,$s) unless $debug;
    my $intents=$s->{intents}; $s->{intents}=[];
    for my $intent (@$intents) {
        next if $intent->{generation} ne $s->{generation};
        next if $s->{conflict};
        if ($intent->{after_exit}) {
            my $trip=$s->{trip}//$s->{last_trip}//{};
            my $proof=($trip->{exits}//{})->{$intent->{after_exit}};
            unless (($trip->{id}//'') eq $intent->{trip} && defined($proof) && $proof==$intent->{exit_time}) {
                GP_Trace($s,$now,'prior exit revoked before dispatch',{rule=>$intent->{rule}}); next;
            }
        }
        if (GP_IsOpening($intent->{kind}) && $s->{phase} =~ /\A(?:away|leaving|unknown)\z/) {
            GP_Trace($s,$now,'opening cancelled by newer position'); next;
        }
        unless (GP_ActionFresh($cfg,$intent->{e},$now)) { GP_Trace($s,$now,'intent expired'); next; }
        if ($debug) {
            GP_Trace($s,$now,'would execute; debug suppressed', {rule=>$intent->{rule},kind=>$intent->{kind},target=>$intent->{params}{target}//'pushMsg'});
            next;
        }
        last unless GP_CanOutput($c,$r,$s);
        my $p=$intent->{params};
        if ($intent->{kind} eq 'notify') {
            my $message=$p->{message}//'';
            $message =~ s/%resident%/$cfg->{label}/g;
            unless (GP_SafeText($message)) { GP_Trace($s,$now,'unsafe notification text rejected'); next; }
            my $ok=eval {GP_Profile($c,'notification','pushMsg',sub {pushMsg($p->{channel}//0,$p->{priority}//0,$message)});1};
            GP_RecordAction($c,$r,$s,$now,$ok?'notification dispatched':'notification failed',
                {rule=>$intent->{rule},channel=>$p->{channel}//0,message=>$message});
            next;
        }
        if ($intent->{kind} eq 'switch_on') {
            # A fixed, idempotent on command; never an opening reservation and
            # never arbitrary FHEM command text. Configuration validates target
            # conflicts with door/garage actions before accepting an event.
            next unless GP_Name($p->{target}) && exists($defs{$p->{target}}) && ($p->{command}//'') eq 'on';
            my $error=eval {GP_Profile($c,'actor_command',$p->{target},sub {CommandSet(undef,$p->{target}.' on')})};
            $error=$@ if $@;
            GP_RecordAction($c,$r,$s,$now,$error ? 'switch command failed':'switch command dispatched',
                {rule=>$intent->{rule},kind=>'switch_on',target=>$p->{target}});
            next;
        }
        my $target=$p->{target};
        my $rt=$c->{helper}{gp};
        # A preceding resident's command may already have completed synchronously
        # in this timer pass. Only a still-pending request can be shared.
        GP_ActorFeedback($c,$now,$mono) if $rt->{actors}{$target};
        last unless GP_CanOutput($c,$r,$s);
        if ($rt->{actors}{$target}) {
            $rt->{actors}{$target}{waiters}{$r}=1;
            GP_Trace($s,$now,'shared actor already pending',{target=>$target});
            $s->{$intent->{kind} eq 'door_open'?'door_result':'garage_result'}='shared';
            next;
        }
        my $view=GP_ActorView($intent,$rt->{start});
        my $result=$intent->{kind} eq 'door_open'?'door_result':'garage_result';
        if ($view eq 'open' || $view eq 'opening') {
            $s->{$result}='already_satisfied'; GP_Trace($s,$now,'actor already open or opening',{target=>$target}); next;
        }
        unless ($view eq 'closed') {
            $s->{$result}='suppressed'; GP_Trace($s,$now,'actor position does not permit opening',{target=>$target,state=>$view}); next;
        }
        # Reserve before CommandSet: DOIF/readings callbacks can run synchronously.
        my $actor=$rt->{actors}{$target}={intent=>$intent,start=>$now,mono=>$mono,waiters=>{$r=>1},timeout=>$cfg->{actor_timeout}};
        for my $ref (GP_ActorFeedbackSources($intent)) {
            $actor->{feedback}{$ref->[0]}{$ref->[1]}={before=>GP_ReadingFingerprint(@$ref)};
        }
        # Subscribe before CommandSet as the complete pulse may be reported
        # synchronously, with the same value and TIME as the previous pulse.
        GP_UpdateNotifyDevices($c);
        $s->{$result}='dispatch_started';
        my $error=eval {GP_Profile($c,'actor_command',$target,sub {CommandSet(undef,$target.' '.$p->{command})})};
        $error=$@ if $@;
        $s->{$result}=$error ? 'failed':'pending';
        GP_RecordAction($c,$r,$s,$now,$error?'actor command failed':'actor command dispatched',
            {target=>$target,rule=>$intent->{rule},kind=>$intent->{kind}});
    }
}

sub GP_Publish {
    my ($c,$r,$cfg,$s)=@_;
    GP_Checkpoint($c,$r,$cfg,$s);
    return unless GP_CanOutput($c,$r,$s);
    my $rr=$defs{$r}{ROOMMATE};
    if (my $status=delete $s->{desired_status}) {
        my $current=GP_Read($rr,'state','unknown');
        my $set=($status eq 'home' && $current !~ /\A(?:home|gotosleep|asleep|awoken)\z/)
            || ($status eq 'absent' && $current !~ /\A(?:absent|gone)\z/);
        if ($set) {
            local $c->{helper}{gp}{own_status}=1;
            GP_Profile($c,'roommate_command',$rr,sub {CommandSet(undef,"$rr state $status")});
        }
    }
    return unless GP_CanOutput($c,$r,$s);
    my $t=$s->{trip}//{};
    my $arrival=$s->{arrival}//{};
    my %readings=(gp_phase=>$s->{phase},gp_location=>$s->{location}//'unknown',gp_trip_id=>$t->{id}//'',
        gp_trip_scope=>$t->{scope}//'unknown',gp_arrival_armed=>$t->{armed}//0,gp_away_reason=>$t->{away_reason}//'',
        gp_source_mode=>$cfg->{sourceMode},
        gp_resume_status=>($s->{resume}//{})->{status}//'none',
        gp_resume_reason=>($s->{resume}//{})->{reason}//'No restart recovery in this session',
        gp_phone_state=>$s->{phone}{state},gp_phone_health=>$s->{phone}{health},gp_phone_signal_mode=>$cfg->{phoneSignalMode},
        gp_geometry_ready=>$cfg->{geometry_ready},gp_geometry_reason=>join('; ',@{$cfg->{geometry_errors}}),
        gp_last_observed=>$s->{last_observed}//'',gp_last_received=>$s->{last_received}//'',
        gp_last_delay=>defined($s->{last_observed}) ? sprintf('%.3f',$s->{last_received}-$s->{last_observed}):'',
        gp_motion=>$s->{motion}//'unknown',gp_motion_time=>$s->{motion_time}//'',
        gp_arrival_pending=>$s->{arrival}?1:0,gp_arrival_motion=>$arrival->{motion}//'',
        gp_arrival_deadline=>$arrival->{deadline}//'',gp_arrival_wait=>$arrival->{wait}//'',
        gp_last_decision=>$s->{last_decision},gp_last_reason=>$s->{last_reason},
        gp_door_result=>$s->{door_result}//'not_requested',gp_garage_result=>$s->{garage_result}//'not_requested',
        gp_evidence_state=>($s->{position_time}//0)>$s->{start} ? 'current_session':'restored');
    my $d=$defs{$r};
    my @changed=grep {GP_Read($r,$_,'__missing__') ne $readings{$_}} sort keys %readings;
    return unless @changed;
    readingsBeginUpdate($d);
    readingsBulkUpdate($d,$_,$readings{$_}) for @changed;
    GP_Profile($c,'resident_reading_callbacks',$r,sub {readingsEndUpdate($d,1)});
}

sub GP_ActorFeedback {
    my ($c,$now,$mono)=@_;
    my $rt=$c->{helper}{gp};
    for my $target (keys %{$rt->{actors}}) {
        my $a=$rt->{actors}{$target}; my $i=$a->{intent};
        my $result=GP_ActorResult($a);
        $result='uncertain' if !$result && $mono-$a->{mono}>$a->{timeout};
        next unless $result;
        # Finish the reservation before calling the logger: Log3 subscribers
        # may reenter this function or create a new request for the same target.
        delete $rt->{actors}{$target};
        for my $r (keys %{$a->{waiters}}) {
            my $s=$rt->{prod}{$r};
            $s->{$i->{kind} eq 'door_open'?'door_result':'garage_result'}=$result if $s;
            GP_RecordAction($c,$r,$s,$now,'actor feedback',{target=>$target,result=>$result,kind=>$i->{kind}});
        }
    }
    GP_UpdateNotifyDevices($c);
}

sub GeoPresence_Timer {
    my ($c)=@_;
    return unless $defs{$c->{NAME}} && $defs{$c->{NAME}}==$c && $c->{helper}{gp};
    return if $c->{helper}{gp_timer_running};
    local $c->{helper}{gp_timer_running}=1;
    my ($now,$mono,$cpu)=(GP_Now(),GP_Mono(),GP_CPU());
    my $due=delete $c->{helper}{gp_timer_due};
    my $lag=defined($due) && $mono>$due ? ($mono-$due)*1000 : 0;
    my $rt=$c->{helper}{gp};
    local $c->{helper}{gp_work}={runtime=>$rt,device_scans=>0,config_builds=>0};
    GP_Profile($c,'timer_registry','remove',sub {RemoveInternalTimer($c,'GeoPresence_Timer')});
    GP_Profile($c,'processing',$c->{NAME},sub {GP_TimerStep($c,$rt,$now,$mono)}) if $init_done;
    my $duration=GP_Mono()-$mono;
    my $stats=$c->{helper}{gp_timer_stats}//={runs=>0,total_ms=>0,max_ms=>0,slow_runs=>0};
    if ($duration>=0.5) {
        if (!defined($stats->{warned_at}) || GP_Mono()-$stats->{warned_at}>=60 || GP_Mono()<$stats->{warned_at}) {
            $stats->{warned_at}=GP_Mono();
            my $sample=GP_TimerSample($c,$now,$mono,$cpu,$lag);
            GP_Log($c,2,'timer_slow',{reason=>'Slow timer work; phase times exclude nested measured calls; this log write is included in timerStats afterwards',
                map {$_=>$sample->{$_}} qw(started_at elapsed_ms cpu_ms start_lag_ms slowest_phase slowest_target slowest_self_ms)});
        }
    }
    # Reading/command callbacks can replace the session and install its timer.
    # Never add another timer to that session or rearm an undefined controller.
    # A slow callback must not schedule its successor in the past.
    GP_Profile($c,'timer_registry','schedule',sub {GP_ScheduleTimer($c,1)}) if GP_TimerCurrent($c,$rt);
    # Include diagnostic output and scheduler calls, even if a synchronous
    # callback replaced the session. No file output from this final accounting.
    my $sample=GP_TimerSample($c,$now,$mono,$cpu,$lag);
    $stats->{runs}++;
    $stats->{last_started_at}=$now;
    $stats->{last_lag_ms}=$lag;
    $stats->{max_lag_ms}=$lag if $lag>($stats->{max_lag_ms}//0);
    $stats->{late_runs}++ if $lag>=500;
    $stats->{last_ms}=$sample->{elapsed_ms};
    $stats->{last_cpu_ms}=$sample->{cpu_ms};
    $stats->{total_ms}+=$stats->{last_ms};
    $stats->{max_ms}=$stats->{last_ms} if $stats->{last_ms}>$stats->{max_ms};
    $stats->{last_device_scans}=$c->{helper}{gp_work}{device_scans};
    $stats->{last_config_builds}=$c->{helper}{gp_work}{config_builds};
    $stats->{profile_started_at}//=$now;
    $stats->{last_run}=$sample;
    $stats->{worst_run}=$sample if !$stats->{worst_run} || $sample->{elapsed_ms}>$stats->{worst_run}{elapsed_ms};
    $stats->{worst_late_run}=$sample if !$stats->{worst_late_run} || $lag>$stats->{worst_late_run}{start_lag_ms};
    if ($sample->{elapsed_ms}>=500) {
        $stats->{slow_runs}++;
        push @{$stats->{recent_slow}},$sample;
        shift @{$stats->{recent_slow}} while @{$stats->{recent_slow}}>12;
    }
    if ($lag>=500) {
        push @{$stats->{recent_late}},$sample;
        shift @{$stats->{recent_late}} while @{$stats->{recent_late}}>12;
    }
}

sub GP_TimerSample {
    my ($c,$now,$mono,$cpu,$lag)=@_;
    my $work=$c->{helper}{gp_work};
    my $elapsed=(GP_Mono()-$mono)*1000; $elapsed=0 if $elapsed<0;
    my $cpu_ms=(GP_CPU()-$cpu)*1000; $cpu_ms=0 if $cpu_ms<0;
    my @phases=sort {$b->{self_ms}<=>$a->{self_ms} || $a->{phase} cmp $b->{phase} || $a->{target} cmp $b->{target}}
        map {{%$_}} values %{$work->{phases}//{}};
    my $top=$phases[0]//{};
    return {started_at=>$now,elapsed_ms=>$elapsed,cpu_ms=>$cpu_ms,start_lag_ms=>$lag,
        device_scans=>$work->{device_scans},config_builds=>$work->{config_builds},phases=>\@phases,
        slowest_phase=>$top->{phase}//'unmeasured',slowest_target=>$top->{target}//'',slowest_self_ms=>$top->{self_ms}//0};
}

sub GP_TimerSampleView {
    my ($sample)=@_;
    return unless $sample;
    my %view=%$sample;
    $view{$_}=0+sprintf('%.3f',$sample->{$_}) for qw(started_at elapsed_ms cpu_ms start_lag_ms slowest_self_ms);
    $view{phases}=[map {{%$_,elapsed_ms=>0+sprintf('%.3f',$_->{elapsed_ms}),self_ms=>0+sprintf('%.3f',$_->{self_ms})}} @{$sample->{phases}}];
    return \%view;
}

sub GP_ScheduleTimer {
    my ($c,$delay)=@_;
    $c->{helper}{gp_timer_due}=GP_Mono()+$delay;
    InternalTimer(GP_Now()+$delay,'GeoPresence_Timer',$c,0);
}

sub GP_TimerCurrent {
    my ($c,$rt)=@_;
    return ($defs{$c->{NAME}}//0)==$c && ($c->{helper}{gp}//0)==$rt;
}

sub GP_TimerStep {
    my ($c,$rt,$now,$mono)=@_;
    my $registration=GP_Profile($c,'listener',$c->{NAME},sub {GP_EnsureHTTP($c)});
    $rt->{ready}=$registration ? 0:1;
    GP_Log($c,2,'listener_error',{reason=>$registration}) if $registration && ($rt->{error}//'') ne $registration;
    $rt->{error}=$registration//'';
    $c->{STATE}=$registration ? 'configuration error':GP_Mode($c->{NAME});
    GP_Profile($c,'actor_feedback',$c->{NAME},sub {GP_ActorFeedback($c,$now,$mono)});
    return unless GP_TimerCurrent($c,$rt);
    for my $r (GP_Residents($c)) {
        GP_ExpireLearning($c,$r);
        my $mode=GP_EffectiveMode($c,$r,0);
        next if $mode eq 'disabled' || $mode eq 'learning';
        my $first_debug=$mode eq 'active' ? 0:1;
        my $first_cfg=GP_Profile($c,'configuration',$r,sub {GP_Config($c,$r,$first_debug)});
        my @errors=GP_Profile($c,'validation',$r,sub {GP_Validate($c,$r,$mode eq 'active',$first_cfg)});
        my $previous=join('; ',@{$rt->{errors}{$r}//[]});
        my $current=join('; ',@errors);
        GP_Log($c,@errors ? 2:3,@errors ? 'configuration_invalid':'configuration_ready',
            {resident=>$r,mode=>$mode,reason=>$current||'Configuration valid'}) if $current ne $previous;
        $rt->{errors}{$r}=\@errors;
        next if @errors;
        my @pools=$mode eq 'active' ? (0) : (1);
        push @pools,1 if $mode eq 'active' && exists $rt->{debug}{$r};
        for my $debug (@pools) {
            my $target=$r.($debug ? ' (debug)':' (production)');
            my $cfg=$debug==$first_debug ? $first_cfg : GP_Profile($c,'configuration',$target,sub {GP_Config($c,$r,$debug)});
            my $s=GP_State($c,$r,$debug,$cfg);
            my $wall=$now+($s->{debug_offset}//0);
            my $clock=$mono+($s->{debug_offset}//0);
            GP_CheckClock($s,$cfg,$wall,$clock);
            if (GP_UsesSource($cfg->{sourceMode},'phone')
                && (!defined($s->{phone_poll_at}) || $clock-$s->{phone_poll_at}>=$cfg->{phone_poll})) {
                my $samples;
                if ($debug && ($s->{phone_mode}//'live') eq 'simulated') {
                    $samples={map {$_=>{value=>$s->{sim_phone}//'absent',time=>$wall,ttl=>150,healthy=>1}} @{$cfg->{proxies}}};
                } else { $samples=GP_Profile($c,'phone_readings',$target,sub {GP_PhoneSamples($cfg,$now)}); }
                my $phone=GP_Profile($c,'phone',$target,sub {GP_Phone($s,$cfg,$samples,$wall,$clock)});
                if ($phone) {
                    push @{$s->{queued_phones}},$phone;
                    if (@{$s->{queued_phones}}>32) {
                        $s->{queued_phones}=[]; delete @{$s}{qw(trip arrival)};
                        GP_ResetNegative($s,$wall);
                        GP_Trace($s,$wall,'phone queue overflow; permissions revoked');
                    }
                }
                $s->{phone_poll_at}=$clock;
            }
            GP_Profile($c,'state_tick',$target,sub {GP_TickState($s,$cfg,$wall,$clock)});
            # Hold the resident's batch until the short reordering window closes.
            my @batch=grep {$_->{resident} eq $r && $_->{debug}==$debug} @{$rt->{queue}};
            my $batch_ready=!grep {$_->{due}>$mono} @batch;
            if ($batch_ready) {
                @{$rt->{queue}}=grep {!($_->{resident} eq $r && $_->{debug}==$debug)} @{$rt->{queue}};
                my @events=map {{%{$_->{event}}}} grep {$_->{epoch}==$rt->{epoch}} @batch;
                my ($geometry_changed,$geometry_conflict)=(0,0);
                my @accepted;
                for my $e (sort {$a->{time}<=>$b->{time}} @events) {
                    my $result=GP_Profile($c,'geometry',$target,sub {GP_UpdateGeometry($c,$r,$debug,$s,$e,$cfg,$wall)});
                    if ($result eq 'stale') {
                        GP_Trace($s,$wall,'stale geometry observation ignored',{zone=>$e->{zone}});
                        # Do not restore older geometry. An otherwise current
                        # exit with UNCHANGED geometry can still disprove the
                        # pending dwell interval, even after a newer Home entry.
                        my $z=$cfg->{zones}{$e->{zone}}//{};
                        push @accepted,$e if GP_InterruptsArrival($s,$cfg,$e)
                            && GP_HasGeometry($e->{geometry}) && GP_HasGeometry($z)
                            && !grep {$e->{geometry}{$_}!=$z->{$_}} qw(lat lon radius);
                        next;
                    }
                    $geometry_changed=1 if $result eq 'changed' || $result eq 'conflict';
                    $geometry_conflict=1 if $result eq 'conflict';
                    push @accepted,$e;
                }
                @events=@accepted;
                GP_MergeBatchMotion(@events);
                $cfg=GP_Config($c,$r,$debug) if $geometry_changed;
                my $conflict=0;
                for my $i (0..$#events) {
                    for my $j ($i+1..$#events) {
                        next unless GP_Fresh($cfg,$events[$i],$wall) && GP_Fresh($cfg,$events[$j],$wall);
                        next if $events[$i]{time}<($s->{position_time}//0) || !GP_AfterStart($s,$cfg,$events[$i]);
                        $conflict=1 if GP_Contradiction($events[$i],$events[$j],$cfg);
                    }
                }
                my $phones=delete($s->{queued_phones})//[];
                push @events,@$phones unless $geometry_changed;
                $conflict=1 if $geometry_conflict;
                my @pending;
                for my $e (sort {$a->{time}<=>$b->{time} || ($a->{zone}//'') cmp ($b->{zone}//'')} @events) {
                    last if $conflict;
                    if ($geometry_changed) {
                        GP_GeometrySync($s,$cfg,$e,$wall,$clock) if $e->{time}>=($s->{position_time}//0);
                        next;
                    }
                    GP_Profile($c,'observation',$target,sub {GP_Process($s,$cfg,$e,$wall,$clock)});
                    @pending=grep {!GP_IsOpening($_->{kind})} @pending if $s->{conflict};
                    # No command runs until all accepted observations in this batch agree.
                    if ($e->{kind} eq 'geo' && !$e->{entry} && ($e->{role}//'') =~ /\A(?:home|approach|outer)\z/) {
                        @pending=grep {!GP_IsOpening($_->{kind}) || $_->{e}{time}>$e->{time}} @pending;
                    }
                    push @pending, @{$s->{intents}};
                }
                if ($conflict) {
                    delete $s->{trip}; GP_CancelArrival($s,$wall,'conflicting batch'); $s->{conflict}=1;
                    GP_Trace($s,$wall,'conflicting batch; actions quarantined');
                }
                $s->{intents}=\@pending;
                # An expired arrival wait may act only after ALL queued Geo and
                # phone observations have been ordered and processed. Never
                # dispatch while an exit is still held by reorder_window.
                GP_Profile($c,'arrival',$target,sub {GP_ConfirmArrival($s,$cfg,$wall,$clock)});
                GP_Profile($c,'dispatch',$target,sub {GP_Dispatch($c,$r,$cfg,$s,$debug,$wall,$clock)});
                return unless GP_TimerCurrent($c,$rt);
            }
            GP_Profile($c,'publish_geometry',$target,sub {GP_PublishGeometry($c,$r,$s)}) unless $debug;
            return unless GP_TimerCurrent($c,$rt);
            GP_Profile($c,'publish',$target,sub {GP_Publish($c,$r,$cfg,$s)}) unless $debug;
            return unless GP_TimerCurrent($c,$rt);
            GP_Profile($c,'trace_output',$target,sub {GP_LogTrace($c,$r,$s,$debug)});
        }
    }
}

sub GeoPresence_Notify {
    my ($c,$device)=@_;
    return unless ($c->{SUBTYPE}//'') eq 'controller';
    my $events=deviceEvents($device,1)//[];
    if ($device->{NAME} eq 'global') {
        if (grep {/\A(?:INITIALIZED|REREADCFG)\z/} @$events) {
            # State restoration has finished, including when REREADCFG arrives
            # before init_done becomes true. Preserve saved modes/timestamps;
            # only genuinely absent modes need the disabled default.
            for my $d ($c,map {$defs{$_}} GP_Residents($c)) {
                GP_StoreMode($d,'disabled') unless length GP_Read($d->{NAME},'mode','');
            }
            GP_UpdateAttrLists();
            GP_ResetController($c,'resume');
        } elsif ($init_done && grep {/\A(?:DEFINED|DELETED|RENAMED) /} @$events) {
            GP_UpdateAttrLists();
        }
        return;
    }
    # Observe only the feedback readings of already dispatched actors. This is
    # passive even when a mode change leaves an outstanding hardware request.
    for my $actor (values %{$c->{helper}{gp}{actors}//{}}) {
        my $watch=$actor->{feedback}{$device->{NAME}} or next;
        my $updated=0;
        for my $reading (keys %$watch) {
            my $value=GP_Read($device->{NAME},$reading,'');
            next unless grep {$_ eq "$reading: $value" || ($reading eq 'state' && $_ eq $value)} @$events;
            $watch->{$reading}{observed}=GP_ReadingFingerprint($device->{NAME},$reading);
            $updated=1;
        }
        if ($updated) {
            # Completion belongs to this reservation, not to the current display.
            # A contact close may reset pulse_state to idle before the next timer;
            # keep the first validated terminal result across all later updates.
            my $result=GP_ActorResult($actor);
            $actor->{completion}//=$result if defined($result);
        }
    }
    return if $c->{helper}{gp}{own_status};
    # ROOMMATE duration updates occur every minute. They cannot be a manual
    # arrival and need neither a resident scan nor a state allocation.
    return unless grep {/\A(?:state: )?home\z/} @$events;
    for my $r (GP_Residents($c)) {
        next unless $defs{$r}{ROOMMATE} eq $device->{NAME};
        next unless GP_EffectiveMode($c,$r,0) eq 'active';
        my $s=GP_State($c,$r,0);
        delete $s->{trip}; GP_CancelArrival($s,GP_Now(),'manual home');
        delete $s->{last_trip}{exits} if $s->{last_trip};
        $s->{members}={};
        $s->{phase}='home'; $s->{boundary}=GP_Now(); $s->{intents}=[];
        $s->{position_time}=$s->{boundary}; $s->{desired_status}='home';
        GP_ResetNegative($s,$s->{boundary});
        GP_Trace($s,GP_Now(),'manual home; no opening');
        GP_ClearCheckpoint($r,'Manual Home state completed the trip');
    }
    return;
}

# FHEMWEB obtains its set menu by calling SetFn with "?". Return whitespace-
# separated command:widget entries, never a usage sentence. The native select
# widget decodes '#' as a space in argument combinations. Merely displaying
# this list must not allocate state, reset a journey or open learning reception.
sub GP_SetList {
    my ($hash)=@_;
    my $kind=$hash->{SUBTYPE}//'';
    if ($kind eq 'resident') {
        return GP_UsesSource(GP_Attr($hash->{NAME},'sourceMode','geofency_phone'),'geo')
            ? 'mode:active,debug,disabled,learning webhookPassword:textField learnConfirm:noArg'
            : 'mode:active,debug,disabled';
    }
    return '' unless $kind eq 'controller';
    my @residents=grep {/\A[A-Za-z0-9_.-]+\z/} GP_Residents($hash);
    my @geo=grep {GP_UsesSource(GP_Attr($_,'sourceMode','geofency_phone'),'geo')} @residents;
    my @phone=grep {GP_UsesSource(GP_Attr($_,'sourceMode','geofency_phone'),'phone')} @residents;
    my %choices=(
        applyGeometry=>\@geo,
        debugReset=>[map {($_,$_.'#keepGeometry')} @residents],
        debugPhoneMode=>[map {($_.'#live',$_.'#simulated')} @phone],
        debugPhone=>[map {($_.'#present',$_.'#absent')} @phone],
        debugAdvance=>[],
    );
    return 'mode:active,debug,disabled '.join(' ',map {$_ . (@{$choices{$_}} ? ':select,,'.join(',',@{$choices{$_}}) : ':textField')}
        sort keys %choices);
}

sub GeoPresence_Set {
    my ($hash,$name,$command,@args)=@_;
    $command //= '?';
    if ($command eq 'mode') {
        return 'Usage: set '.$name.' mode active|debug|disabled'.(($hash->{SUBTYPE}//'') eq 'resident'?'|learning':'') unless @args==1;
        return GP_SetMode($hash,$args[0]);
    }
    if (($hash->{SUBTYPE}//'') eq 'resident' && $command eq 'learnConfirm') {
        return 'Usage: set '.$name.' learnConfirm' if @args;
        return GP_LearnConfirm(GP_Controller($hash),$name);
    }
    if (($hash->{SUBTYPE}//'') eq 'resident' && $command eq 'webhookPassword') {
        return 'Resident has no Geofency source' unless GP_UsesSource(GP_Attr($name,'sourceMode','geofency_phone'),'geo');
        my $c=GP_Controller($hash);
        return 'Controller unavailable' unless $c && $c->{helper}{gp};
        my $guard=GP_ConfigChangeError($c,$hash); return $guard if $guard;
        return 'Replace the password placeholder before using this command' if @args==1 && $args[0] =~ /\A__.*__\z/;
        return 'Use a random password of 24..128 characters: A-Z a-z 0-9 _ -'
            unless @args==1 && $args[0] =~ /\A[A-Za-z0-9_-]{24,128}\z/;
        open my $random,'<:raw','/dev/urandom' or return 'Random source unavailable';
        my $bytes=''; my $n=read($random,$bytes,16); close $random;
        return 'Random source unavailable' unless defined($n) && $n==16;
        my $salt=unpack('H*',$bytes);
        my $error=setKeyValue('GeoPresence_'.$name.'_auth',$salt.':'.sha256_hex($salt.':'.$args[0]));
        return $error if $error;
        delete $GP_AUTH{$name}; delete $c->{helper}{gp}{learned}{$name};
        GP_ResetResident($c,$name); GP_UpdateModes($c);
        return 'Webhook password stored in the FHEM key store';
    }
    return 'Unknown argument, choose one of '.GP_SetList($hash)
        if ($hash->{SUBTYPE}//'') ne 'controller'
            || $command !~ /\A(?:applyGeometry|debugReset|debugPhoneMode|debugPhone|debugAdvance)\z/;
    unless (@args) {
        my %extra=(debugReset=>' [keepGeometry]',debugPhoneMode=>' live|simulated',
            debugPhone=>' present|absent',debugAdvance=>' seconds');
        return "Usage: set $name $command resident".($extra{$command}//'');
    }
    my ($r,$value)=@args;
    return 'Unknown resident' unless GP_Field($r,'SUBTYPE','') eq 'resident' && GP_Field($r,'CONTROLLER','') eq $name;
    my $rt=$hash->{helper}{gp};
    if ($command eq 'applyGeometry') {
        return 'Usage: set controller applyGeometry resident' unless @args==1;
        return GP_ApplyGeometry($hash,$r);
    }
    return 'Debug commands are unavailable during learning; use learnConfirm or set resident mode disabled' if GP_EffectiveMode($hash,$r,0) eq 'learning';
    return 'Resident is disabled' if GP_EffectiveMode($hash,$r,1) eq 'disabled';
    if ($command eq 'debugReset') {
        return 'Usage: set controller debugReset resident [keepGeometry]'
            unless @args==1 || (@args==2 && $value eq 'keepGeometry');
        my $keep_geometry=defined($value) && $value eq 'keepGeometry';
        return 'keepGeometry requires a real-time debug session; use debugReset without keepGeometry after debugAdvance'
            if $keep_geometry && (($rt->{debug}{$r}//{})->{debug_offset}//0)!=0;
        delete $rt->{learning}{$r};
        delete $rt->{learned}{$r} if ($rt->{learned}{$r}//{})->{unbound};
        # Coordinates are reusable setup data, not evidence of a trip. Keep
        # their timestamps and conflict flags intact; all journey state and
        # queued observations are discarded even when geometry is retained.
        delete $rt->{geometry}{debug}{$r} unless $keep_geometry;
        $rt->{debug}{$r}=GP_NewState(GP_Now()-31,GP_Mono()-31,$rt->{epoch}.':debug:'.$r.':'.GP_Now(),GP_Attr($r,'sourceMode','geofency_phone'));
        @{$rt->{queue}}=grep {!($_->{debug} && $_->{resident} eq $r)} @{$rt->{queue}};
        return $keep_geometry ? 'Debug session reset; geometry retained; no productive changes' : 'Debug session reset; no productive changes';
    }
    my $phone=GP_UsesSource(GP_Attr($r,'sourceMode','geofency_phone'),'phone');
    return 'Phone source disabled by sourceMode; debugPhoneMode and debugPhone are unavailable'
        if !$phone && $command =~ /\AdebugPhone(?:Mode)?\z/;
    my $s=GP_State($hash,$r,1);
    if ($command eq 'debugPhoneMode') {
        return 'Choose live or simulated' unless defined($value) && $value =~ /\A(?:live|simulated)\z/;
        $s->{phone_mode}=$value; $s->{phone}=GP_NewPhone();
    } elsif ($command eq 'debugPhone') {
        return 'debugPhoneMode must be simulated' unless ($s->{phone_mode}//'') eq 'simulated';
        return 'Choose present or absent' unless defined($value) && $value =~ /\A(?:present|absent)\z/;
        $s->{sim_phone}=$value;
    } elsif ($command eq 'debugAdvance') {
        return 'debugAdvance requires simulated phone or geofency_only and 1..86400 seconds' unless (!$phone || ($s->{phone_mode}//'') eq 'simulated')
            && defined($value) && $value =~ /\A\d+\z/ && $value>=1 && $value<=86400;
        $s->{debug_offset}+=$value;
    }
    return 'Debug state updated; no productive changes';
}

# Presentation reads snapshots only. Never call GP_State, GP_Rules, GP_Phone,
# GP_ConfirmArrival or a dispatcher from these helpers: a get is not an event.
sub GP_ReportTime {
    my ($time)=@_;
    return 'Not observed' unless defined($time) && GP_Number($time) && $time>0;
    return POSIX::strftime('%Y-%m-%d %H:%M:%S %Z',localtime($time));
}

sub GP_ReportDuration {
    my ($seconds)=@_;
    return 'Unknown' unless defined($seconds) && GP_Number($seconds);
    $seconds=0 if $seconds<0;
    return sprintf('%.1f s',$seconds) if $seconds<60;
    return sprintf('%d min %02d s',int($seconds/60),int($seconds)%60) if $seconds<3600;
    return sprintf('%d h %02d min',int($seconds/3600),int($seconds/60)%60);
}

sub GP_ReportValue {
    my ($text)=@_;
    $text//='';
    $text=decode('UTF-8',$text) if !$unicodeEncoding && !utf8::is_utf8($text);
    $text =~ s/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/ /g;
    return $text;
}

sub GP_ReportEscape {
    my ($text)=@_;
    $text=GP_ReportValue($text);
    $text =~ s/&/&amp;/g; $text =~ s/</&lt;/g; $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g; $text =~ s/'/&#39;/g;
    # Some FHEMWEB versions encode Unicode only when compressing the response.
    # Numeric entities render identically with or without gzip in either mode.
    $text =~ s/([^\x00-\x7f])/sprintf('&#x%X;',ord($1))/eg;
    return $text;
}

sub GP_ReportJSON {
    my ($value,$web)=@_;
    my $json=$web ? JSON::PP->new->canonical->ascii->encode($value) : $GP_JSON->encode($value);
    # FHEMWEB inserts even a JSON response into a <pre> using .html().
    # Escapes preserve decoded values and prevent executable markup.
    $json =~ s/([<>&])/sprintf('\\u%04x',ord($1))/eg if $web;
    return $json;
}

sub GP_ReportCell {
    my ($text)=@_;
    my $escaped=GP_ReportEscape($text);
    if (defined($text) && GP_Name($text) && exists($defs{$text}) && defined($FW_ME)) {
        return '<a href="'.GP_ReportEscape($FW_ME.($FW_subdir//'').'?detail='.$text).'">'.$escaped.'</a>';
    }
    return $escaped;
}

sub GP_ReportLine {
    my ($text,$prefix)=@_;
    # One complete value per line; the terminal controls any visual wrapping.
    return ($prefix//'').GP_ReportValue($text)."\n";
}

sub GP_RenderReport {
    my ($report,$html)=@_;
    my $title=$report->{title}//'GeoPresence';
    # jQuery UI otherwise focuses the first device link and scrolls past the summary.
    my $out=$html ? '<html><div class="gp-report" tabindex="-1" autofocus style="width:min(64rem,calc(100vw - 4rem));max-width:100%;box-sizing:border-box;white-space:normal;overflow-wrap:anywhere;line-height:1.45;outline:none">'
        : '';
    if (length($report->{banner}//'')) {
        my $banner='=== '.$report->{banner}.' ===';
        $out.=$html ? '<p><strong>'.GP_ReportEscape($banner).'</strong></p>' : "$banner\n";
    }
    $out.=$html ? '<h3>'.GP_ReportEscape($title).'</h3>' : GP_ReportLine($title);
    for my $key (qw(subtitle context notice lead)) {
        next unless length($report->{$key}//'');
        $out.=$html ? '<p>'.($key eq 'lead'?'<strong>':'').GP_ReportEscape($report->{$key})
            .($key eq 'lead'?'</strong>':'').'</p>' : GP_ReportLine($report->{$key});
    }
    for my $section (@{$report->{sections}//[]}) {
        my $heading=$section->{heading}//'';
        # An explicit collapsed value enables folding; false starts expanded.
        my $collapsible=exists $section->{collapsed};
        if ($html) {
            $out.=$collapsible ? '<details'.($section->{collapsed} ? '' : ' open').' style="margin:1em 0"><summary style="cursor:pointer;font-weight:bold">'.GP_ReportEscape($heading).'</summary>'
                : '<h4>'.GP_ReportEscape($heading).'</h4>';
        } elsif (length $heading) { $out.="\n".uc($heading)."\n".('-' x length($heading))."\n"; }
        if (my $note=$section->{note}) {
            $out.=$html ? '<p>'.GP_ReportEscape($note).'</p>' : GP_ReportLine($note,'  ');
        }
        if (my $commands=$section->{commands}) {
            $out.=$html ? '<pre style="white-space:pre-wrap;overflow-wrap:anywhere">'.join("\n",map {GP_ReportEscape($_)} @$commands).'</pre>'
                : join("\n",@$commands)."\n";
        }
        my $rows=$section->{rows}//[];
        my $columns=$section->{columns}//['Item','Status'];
        if (@$rows) {
            my $width=0;
            for my $row (@$rows) {
                my $length=length(GP_ReportValue($row->[0]));
                $width=$length if $length>$width;
            }
            $out.='<table class="block" style="width:100%;table-layout:fixed;border-collapse:collapse"><thead><tr>'
                .join('',map {'<th style="text-align:left;padding:.4em;vertical-align:top">'.GP_ReportEscape($_).'</th>'} @$columns).'</tr></thead><tbody>' if $html;
            my $first_row=1;
            for my $row (@$rows) {
                if ($html) {
                    $out.='<tr>'.join('',map {'<td style="padding:.4em;vertical-align:top;white-space:normal;overflow-wrap:anywhere">'.GP_ReportCell($_).'</td>'} @$row).'</tr>';
                } elsif (@$columns==2) {
                    my $label=GP_ReportValue($row->[0]);
                    my $prefix='  '.sprintf('%-*s',$width,$label).' : ';
                    $out.=GP_ReportLine($row->[1],$prefix);
                } else {
                    $out.="\n" unless $first_row;
                    $out.=GP_ReportLine($row->[0]);
                    $out.=GP_ReportLine($row->[$_],'  '.$columns->[$_].': ') for 1..$#$columns;
                }
                $first_row=0;
            }
            $out.='</tbody></table>' if $html;
        }
        $out.='</details>' if $html && $collapsible;
    }
    $out.='</div></html>' if $html;
    return $out;
}

sub GP_ReportTrace {
    my ($trace,$limit,$all)=@_;
    my @rows;
    for my $row (reverse @{$trace//[]}) {
        next if !$all && $row->{diagnostic_only};
        my $reason=$row->{reason}//'Unknown';
        $reason.='; return permission '.($row->{departure_armed}?'granted':'not granted') if exists $row->{departure_armed};
        $reason.='; '.$row->{confirmation} if length($row->{confirmation}//'');
        my $cause='Not recorded';
        for my $key (qw(rule zone source target)) {
            next unless defined($row->{$key}) && length($row->{$key});
            $cause=$row->{$key}; last;
        }
        push @rows,[GP_ReportTime($row->{time}),$reason,$cause];
        last if @rows>=$limit;
    }
    return {heading=>'Recent decisions',columns=>['Time','Decision','Rule / source'],rows=>\@rows,
        note=>@rows ? 'Newest first. This is recorded history, not a new evaluation.' : 'No decisions recorded in this session.'};
}

sub GP_ReportActorResult {
    my ($result)=@_;
    my %labels=(not_requested=>'No request in this session',dispatch_started=>'Dispatch started',
        pending=>'Request sent; awaiting feedback',shared=>'Sharing a pending request; awaiting feedback',
        confirmed=>'Opening confirmed',uncertain=>'Feedback timeout; outcome uncertain',failed=>'Command failed',
        suppressed=>'Opening suppressed by actuator state',already_satisfied=>'Actuator was already open or opening');
    return $labels{$result//'not_requested'}//$result;
}

sub GP_ReportResident {
    my ($c,$r,$s,$cfg,$debug,$errors,$now,$mono,$value)=@_;
    my $mode=GP_EffectiveMode($c,$r,0);
    my $paused=!$debug && $mode ne 'active';
    my $trip=$s->{trip}//{}; my $phone=$s->{phone}//{}; my $arrival=$s->{arrival};
    my $phase=$s->{phase}//'unknown';
    my $armed=$trip->{armed} && !$s->{conflict};
    my $remaining=$arrival ? $arrival->{due_mono}-$mono:0;
    my $lead= $mode eq 'learning' ? 'Learning setup data — no presence evaluation or actions' : !@{$errors//[]} ? '' : 'Configuration invalid — evaluation suspended';
    $lead||= $mode eq 'disabled' ? 'Disabled — no new actions'
        : $paused ? 'Production evaluation paused — displayed state is not being processed'
        : !$value->{initialized} ? 'Not initialized — no observations processed in this view'
        : $cfg->{sourceMode} eq 'phone_only' ? 'Phone presence only — no automatic opening'
        : !$cfg->{geometry_ready} ? 'No opening planned — location geometry is not ready'
        : $s->{conflict} ? 'No opening planned — conflicting observations'
        : $arrival ? ($remaining>0 ? 'Arrival pending — confirmation in '.GP_ReportDuration($remaining) : 'Arrival confirmation due — waiting for event processing')
        : $armed ? 'Departure confirmed — waiting for return'
        : keys(%$trip) ? ($cfg->{sourceMode} eq 'geofency_only'
            ? 'Departure not confirmed — additional distance evidence required'
            : 'Departure not confirmed — waiting for qualified phone absence')
        : $phase eq 'home' ? 'At home — no new opening planned'
        : 'No opening planned — departure not confirmed';
    my $report={title=>'GeoPresence · '.GP_LogResident($r),banner=>$debug?'DEBUG':'PRODUCTION',
        subtitle=>$r.' · Snapshot '.GP_ReportTime($now),
        notice=>$debug?'Simulation only — no device commands, messages or ROOMMATE changes.':'',
        lead=>$lead,sections=>[]};
    my @summary=(['Resident mode',GP_Mode($r)],['Controller mode',GP_Mode($c->{NAME})],['Effective mode',$mode],
        ['Mode reason',GP_ModeReason($c,$r)],['Source profile',$cfg->{sourceMode}],['Presence',$value->{initialized}?ucfirst($phase):'Not initialized'],
        [$debug?'Simulated status':'ROOMMATE status',$debug ? ($s->{desired_status}//($phase eq 'home'?'home':'Not set')) : GP_Read($cfg->{roommate},'state','unknown')],
        ['Departure',$armed ? 'Confirmed: '.($trip->{away_reason}//'current trip') : 'Not confirmed'],
        ['Trip',keys(%$trip) ? ucfirst($trip->{scope}//'unknown') : 'No active trip'],
        ['Phone',GP_UsesSource($cfg->{sourceMode},'phone')
            ? ucfirst($phone->{state}//'unknown').' ('.($debug && ($s->{phone_mode}//'live') eq 'simulated' ? 'simulated' : $phone->{health}//'unknown').')' : 'Disabled by source profile; no phone fallback'],
        ['Motion',$arrival ? ucfirst($arrival->{motion}) : ucfirst(GP_ArrivalMotion($s,$cfg,$now))]);
    if ($arrival) {
        push @summary,['Home entry received',GP_ReportTime($arrival->{started})],
            ['Confirmation due',GP_ReportTime($arrival->{deadline}).' — wait '.GP_ReportDuration($arrival->{wait})],
            ['Remaining at snapshot',GP_ReportDuration($remaining)];
    } elsif (defined($trip->{home_exit})) {
        push @summary,['Home exit',GP_ReportTime($trip->{home_exit})];
        push @summary,['Phone absence qualification',GP_ReportDuration($mono-$phone->{negative_since}).' / '.GP_ReportDuration($cfg->{phone_absence_window})]
            if !$armed && defined($phone->{negative_since});
    }
    my $resume=$s->{resume}//{};
    push @summary,['Restart recovery',ucfirst($resume->{status}).': '.$resume->{reason}]
        if !$debug && ($resume->{status}//'none') ne 'none';
    push @{$report->{sections}},{id=>'status',heading=>'Status',rows=>\@summary,
        note=>$debug ? 'Simulation only. No productive ROOMMATE changes, actuator commands or messages.' : 'Presence alone does not confirm an opening request.'};
    push @{$report->{sections}},{%{GP_ReportTrace($s->{trace},5,0)},id=>'history',collapsed=>0};
    my @actions;
    for my $rule (@{$cfg->{rules}}) {
        next unless $rule->{trigger} eq 'arrival' && GP_IsOpening($rule->{type});
        my $garage=$rule->{type} eq 'garage_open';
        my $eligible=$arrival ? $arrival->{vehicle_eligible}:GP_VehicleEligible($s,$cfg,$now);
        my $assessment= $mode eq 'disabled' ? 'Disabled'
            : $paused ? 'Production evaluation paused'
            : @{$errors//[]} ? 'Blocked by invalid configuration'
            : !$value->{initialized} ? 'State not initialized; no opening permission'
            : !$cfg->{geometry_ready} ? 'Blocked by missing or inconsistent geometry'
            : !($garage?$cfg->{allowGarage}:$cfg->{allowDoor}) ? 'Resident has no permission'
            : !$armed ? 'No qualified active trip'
            : ($rule->{arrivalFilter}//'any') eq 'vehicle' && !$eligible ? 'No qualifying car or remote evidence, or current walking/cycling'
            : length($rule->{afterExit}//'') && !defined(GP_ExitEvidence($s,$rule->{afterExit},$arrival ? $arrival->{event}{time}:$now)) ? 'Required prior exit not observed in this trip'
            : $arrival ? 'Eligible after arrival confirmation; no request sent yet' : 'Waiting for a valid return';
        my $previous=$s->{$garage?'garage_result':'door_result'};
        $assessment='No new request planned; latest result: '.GP_ReportActorResult($previous)
            if !$armed && !$arrival && $phase eq 'home' && defined($previous) && $previous ne 'not_requested' && !@{$errors//[]} && $mode ne 'disabled' && !$paused;
        push @actions,[$garage?'Garage':'Front door',$rule->{name},$assessment];
    }
    push @{$report->{sections}},{id=>'actions',heading=>'Arrival actions',collapsed=>1,columns=>['Action','Rule','Current assessment'],rows=>\@actions,
        note=>@actions ? 'Actuator conditions are checked before dispatch. Eligibility does not mean a command has been sent.' : 'No enabled arrival-opening rules apply to this resident.'};
    my @rules=map {[$_->{name},$_->{trigger},$_->{trigger} eq 'arrival' ? 'Confirmed return'
        : length($_->{group}//'') ? 'Group: '.$_->{group} : join(', ',@{$_->{locations}}),
        $_->{afterExit} || 'None',$_->{arrivalFilter}//'any',$_->{action}]} @{$cfg->{rules}};
    push @{$report->{sections}},{id=>'rules',heading=>'Configured rules',collapsed=>1,
        columns=>['Rule','Trigger','Locations / group','Required prior exit','Arrival filter','Action'],rows=>\@rules,
        note=>'Group membership and prior exits belong to this resident only. A required prior exit must precede the event in the current trip.'};
    my @sensor_rows;
    if (!GP_UsesSource($cfg->{sourceMode},'phone')) {
        push @sensor_rows,['Not used','Disabled','Source profile geofency_only','No phone readings are evaluated'];
    } elsif ($debug && ($s->{phone_mode}//'live') eq 'simulated') {
        push @sensor_rows,['All simulated sensors',$s->{sim_phone}//'absent','Simulation','No physical measurement'];
    } else {
        my $samples=GP_PhoneSamples($cfg,$now);
        for my $name (@{$cfg->{proxies}}) {
            my $v=$samples->{$name};
            push @sensor_rows,[$name,$v->{value}//'unknown',$v->{healthy}?'Source reports healthy':'Source unavailable or inconsistent',GP_ReportTime($v->{time})];
        }
    }
    push @{$report->{sections}},{id=>'sensors',heading=>'Phone sensors',collapsed=>1,columns=>['Sensor','State','Source health','Observed'],rows=>\@sensor_rows,
        note=>GP_UsesSource($cfg->{sourceMode},'phone')
            ? 'Current source readings; the summary above is the last processed phone state. Last positive observation: '.GP_ReportTime($phone->{latest})
            : 'Home exit and elapsed time alone cannot authorize opening. Additional distance evidence is required. If the Home webhook is lost, there is no phone fallback.'};
    my @zones;
    for my $name (sort keys %{$cfg->{zones}}) {
        my $zone=$cfg->{zones}{$name};my $observation=($s->{zones}//{})->{$name};
        push @zones,[$name,$zone->{role},join(', ',@{$zone->{groups}}) || 'None',$observation ? ($observation->{entry}?'Entered':'Left').' — '.GP_ReportTime($observation->{time}) : 'Not observed',
            GP_HasGeometry($zone) ? $zone->{radius}.' m; '.($zone->{blocked}?'conflicting':'known') : 'Not learned'];
    }
    my @missing_geometry=GP_MissingGeometry($cfg);
    push @{$report->{sections}},{id=>'locations',heading=>'Locations and geometry',collapsed=>1,columns=>['Location','Function','Groups','Last observation','Radius / geometry'],rows=>\@zones,
        note=>!GP_UsesSource($cfg->{sourceMode},'geo') ? 'Locations are not used by phone_only; Geo webhooks and learning are unavailable.'
            : @{$cfg->{geometry_errors}//[]} ? join('; ',@{$cfg->{geometry_errors}})
            : @missing_geometry ? 'Opening geometry is ready, but other registered locations still lack geometry: '.join(', ',@missing_geometry).'. The automatic test application also needs these locations.'
            : 'Geometry is available for all registered locations; opening geometry checks passed.'};
    my @results;
    for my $kind (qw(door garage)) {
        push @results,['Latest '.$kind.' result',GP_ReportActorResult($s->{$kind.'_result'})];
    }
    my $actors=($c->{helper}{gp}//{})->{actors}//{};
    for my $target (sort keys %$actors) {
        my $actor=$actors->{$target};
        next unless exists(($actor->{waiters}//{})->{$r});
        push @results,[$target,($debug?'Existing production request: ':'').'Awaiting feedback since '.GP_ReportTime($actor->{start})];
    }
    push @{$report->{sections}},{id=>'feedback',heading=>'Actuator feedback',collapsed=>1,rows=>\@results,
        note=>'Results describe previously requested operations. They do not create permission for another opening.'};
    my @technical=(['Controller',$c->{NAME}],['Resident',$r],['ROOMMATE',$cfg->{roommate}],
        ['Session started',GP_ReportTime($s->{start})],['Session ID',$s->{generation}//'Not initialized'],
        ['Trip ID',$trip->{id}//'None'],['Last decision',$s->{last_reason}//'No decision recorded'],
        ['Last observation',GP_ReportTime($s->{last_observed})],['Last received',GP_ReportTime($s->{last_received})]);
    push @technical,map {['Configuration error',$_]} @{$errors//[]};
    push @{$report->{sections}},{id=>'technical',heading=>'Technical details',collapsed=>1,rows=>\@technical,
        note=>'Full machine-readable state is available with format=json. Only a validated qualified trip checkpoint can resume; a new return is still required.'};
    if ($debug) {
        push @{$report->{sections}},{id=>'readiness',heading=>'Debug readiness',rows=>[
            ['Debug ready',$value->{debug_ready}?'Yes':'No: '.join('; ',@{$value->{debug_blockers}})],
            ['Geometry ready',$cfg->{geometry_ready}?'Yes':'No'],
            ['Missing location geometry',@missing_geometry ? join(', ',@missing_geometry):'None'],
            ['Geometry-preserving reset','Supported'],['Test webhook isolation','Supported']],
            note=>'Opening geometry checks do not require ordinary places. Automatic tests need every registered location. Readiness does not grant opening permission.'};
    }
    return $report;
}

sub GP_GetReport {
    my ($hash,$command,$args,$value,$limit)=@_;
    my $c=GP_Controller($hash);my $now=GP_Now();
    my $report={title=>'GeoPresence · '.$command,sections=>[]};
    if ($command eq 'validate') {
        $report->{title}=$value->{valid}?'OK: configuration valid':'Configuration invalid';
        $report->{lead}=@{$value->{warnings}}?'Review the following notices.':'Validation does not execute actions.';
        for my $group (['Errors','errors'],['Notices','warnings']) {
            next unless @{$value->{$group->[1]}};
            my %seen;
            my @messages=grep {!$seen{$_}++} @{$value->{$group->[1]}};
            push @{$report->{sections}},{heading=>$group->[0],columns=>['Device','Finding'],rows=>[
                map {/\A([A-Za-z0-9_.-]+):\s*(.*)\z/s ? [$1,$2] : [$c->{NAME},$_]} @messages]};
        }
    } elsif ($command eq 'locationCommands') {
        $report->{sections}=[{heading=>'Commands to copy',commands=>$value->{commands},note=>'Review and execute these commands yourself; this query changes no devices.'}];
    } elsif ($command eq 'learnedLocations') {
        $report->{subtitle}=$args->[0];
        $report->{lead}=@$value ? scalar(@$value).' captured locations; definitions are not created automatically.' : 'No locations captured yet.';
        my $learned=GP_Learned($c,$args->[0]);
        my $receiving=$c->{helper}{gp}{learning}{$args->[0]};
        my $status=$learned->{expired} && !$learned->{confirmed} ? 'Expired; resident disabled' : !$receiving ? 'Stopped' : GP_Mono()>$learned->{until} ? 'Expired; no further webhooks accepted' : 'Receiving test webhooks';
        $report->{sections}=[{heading=>'Device learning',rows=>[
            ['Device ID',length($learned->{device}) ? $learned->{device} : 'Waiting for first authenticated test webhook'],
            ['Binding',$learned->{unbound} ? 'Not configured; confirm with set resident learnConfirm' : 'Configured'],
            ['Confirmation',$learned->{confirmed}?'Confirmed':'Awaiting set resident learnConfirm'],['Reception',$status]],
            note=>'learnConfirm confirms captured setup data and leaves the resident disabled. An existing deviceId is never replaced. Set mode disabled to cancel unconfirmed learning; save after completing setup.'},
            {heading=>'Captured locations',columns=>['Number','Name','Zone ID','Radius','Received'],rows=>[
            map {['@'.$_->{number},$_->{name},$_->{id},(($_->{geometry}//{})->{radius}//'?').' m',GP_ReportTime($_->{time})]} @$value]}];
    } elsif ($command eq 'logStatus') {
        $report->{lead}=length($value->{error})?'Diagnostic write error recorded':'No diagnostic write error recorded';
        $report->{sections}=[{heading=>'Log output',rows=>[
            ['Normal output','FHEM log'],['Normal verbosity',$value->{verbose}],['Diagnostic file',length($value->{file})?$value->{file}:'Not configured'],
            ['Diagnostic setting',$value->{debugLog}],['Simulation diagnostics',$value->{debugEnabled}?'Enabled':'Disabled'],
            ['Learning diagnostics',$value->{learningEnabled}?'Enabled':'Disabled'],
            ['Production diagnostics',$value->{activeEnabled}?'Enabled':'Disabled'],['Diagnostic limit',$value->{rate_limit}.' entries / minute'],
            ['Last write error',$value->{error}||'None']],note=>'Enabled describes configuration, not a write-permission test. This query writes no log entries.'}];
    } elsif ($command eq 'timerStats') {
        $report->{sections}=[{heading=>'Timer work',rows=>[map {[$_->[0],$value->{$_->[1]}.' ms']} ['Last','last_ms'],['Mean','mean_ms'],['Maximum','max_ms']]},
            {heading=>'Delayed starts',rows=>[map {[$_->[0],$value->{$_->[1]}.' ms']} ['Last','last_lag_ms'],['Maximum','max_lag_ms']],note=>'Start delay is separate from work performed by GeoPresence.'},
            {heading=>'Counters',rows=>[['Runs',$value->{runs}],['Slow runs',$value->{slow_runs}],['Late starts',$value->{late_runs}],
                ['Device scans (last run)',$value->{last_device_scans}],['Configuration builds (last run)',$value->{last_config_builds}],['Last start',GP_ReportTime($value->{last_started_at})]]}];
        if (my $run=$value->{worst_run}) {
            push @{$report->{sections}},{heading=>'Slowest profiled run',rows=>[
                ['Started',GP_ReportTime($run->{started_at})],['Elapsed',$run->{elapsed_ms}.' ms'],['Process CPU (approx.)',$run->{cpu_ms}.' ms'],
                ['Start delay',$run->{start_lag_ms}.' ms'],['Largest self time',$run->{slowest_phase}],['Device / context',$run->{slowest_target}],
                ['Self time',$run->{slowest_self_ms}.' ms'],['Profiling since',GP_ReportTime($value->{profile_started_at})]],
                note=>'Elapsed time includes synchronous FHEM callbacks and operating-system pauses. CPU time has platform-dependent resolution; low CPU does not identify a particular wait. Older aggregate maxima may predate profiling.'};
            my @phases=@{$run->{phases}}; splice @phases,6 if @phases>6;
            push @{$report->{sections}},{heading=>'Phase breakdown of slowest run',columns=>['Phase','Device / context','Calls','Elapsed','Self'],
                rows=>[map {[$_->{phase},$_->{target},$_->{calls},$_->{elapsed_ms}.' ms',$_->{self_ms}.' ms']} @phases],
                note=>'Largest six self-time totals. Elapsed includes nested measured calls; Self excludes them. Do not add inclusive elapsed times. Full breakdown: format=json.'};
        }
        for my $group ([recent_slow=>'Recent slow runs'],[recent_late=>'Recent delayed starts']) {
            my @runs=reverse @{$value->{$group->[0]}};
            splice @runs,5 if @runs>5;
            push @{$report->{sections}},{heading=>$group->[1],columns=>['Started','Work','Start delay','Largest self time','Device / context'],
                rows=>[map {[GP_ReportTime($_->{started_at}),$_->{elapsed_ms}.' ms',$_->{start_lag_ms}.' ms',$_->{slowest_phase},$_->{slowest_target}]} @runs],
                note=>@runs ? 'Newest five entries; format=json retains up to twelve with full phase timings. A delayed start alone does not establish GeoPresence as the cause.' : 'No matching profiled runs recorded.'};
        }
    } elsif ($command eq 'debugTrace') {
        $report->{banner}='DEBUG';
        $report->{subtitle}=$args->[0]//$hash->{NAME};
        $report->{lead}='Simulation history — no productive actions';
        $report->{sections}=[GP_ReportTrace($value,$limit//20,1)];
        $report->{sections}[0]{note}='Showing up to '.($limit//20).' newest entries of '.scalar(@$value).'. Use limit=100 or format=json for more history.';
    } else {
        my $r=$args->[0]// $hash->{NAME};
        my $debug=$value->{view} eq 'debug';
        my $s=$value->{state};
        my $cfg=GP_Config($c,$r,$debug);
        $report=GP_ReportResident($c,$r,$s,$cfg,$debug,$value->{errors},
            $value->{snapshot_at},GP_Mono()+($debug?($s->{debug_offset}//0):0),$value);
    }
    return $report;
}

# Use FHEMWEB's native select widget. '#' is decoded to an argument separator
# by fhemweb.js, just as it is for the controller's set commands.
sub GP_GetList {
    my ($hash)=@_;
    my $c=GP_Controller($hash);
    my @choices=($hash->{SUBTYPE}//'') eq 'resident' ? ('prod','debug')
        : $c ? map {($_,$_.'#prod',$_.'#debug')} grep {/\A[A-Za-z0-9_.-]+\z/} GP_Residents($c) : ();
    return 'validate learnedLocations locationCommands debugTrace explain:'
        .(@choices ? 'select,'.join(',',@choices) : 'textField').' logStatus timerStats';
}

sub GeoPresence_Get {
    my ($hash,$name,$command,@args)=@_;
    $command//='?';
    return 'Unknown argument, choose one of '.GP_GetList($hash)
        if $command eq '?';
    my $web=(($hash->{CL}//{})->{TYPE}//'') eq 'FHEMWEB';
    # FHEMWEB's addLinks regex also rewrites HTML attributes and JSON strings.
    # Our HTML links are escaped explicitly; JSON must remain machine-readable.
    delete $FW_webArgs{addLinks} if $web;
    my ($format,$limit,$error);my @positional;
    for my $arg (@args) {
        if ($arg =~ /\Aformat=(.*)\z/) {
            my $requested=$1;
            $error='Choose format=json, format=text or format=html (once)' if defined($format) || $requested !~ /\A(?:json|text|html)\z/;
            $format=$requested;
        } elsif ($arg =~ /\Alimit=(.*)\z/) {
            my $requested=$1;
            $error='limit requires debugTrace and an integer from 1 to 1000 (once)' if defined($limit) || $command ne 'debugTrace' || $requested !~ /\A[1-9][0-9]{0,3}\z/ || $requested>1000;
            $limit=$requested;
        } else {push @positional,$arg;}
    }
    my %counts=(logStatus=>0,timerStats=>0,validate=>1,learnedLocations=>1,locationCommands=>4,debugTrace=>1);
    $error='Too many arguments; optional output: format=json|text|html' if exists($counts{$command}) && @positional>$counts{$command};
    if ($command eq 'explain') {
        my $resident=($hash->{SUBTYPE}//'') eq 'resident';
        unshift @positional,$name if $resident && (!@positional || $positional[0] =~ /\A(?:prod|debug)\z/);
        $error='Usage: get '.$name.' explain '.($resident?'[resident]':'resident').' [prod|debug] [format=json|text|html]'
            if @positional>2 || (@positional>1 && $positional[1] !~ /\A(?:prod|debug)\z/);
    }
    $format//= $web?'html':'text';
    my ($value,$data_error)=$error ? (undef,$error):GP_GetData($hash,$name,$command,@positional);
    if ($data_error) {
        return GP_ReportJSON({error=>$data_error},$web) if $format eq 'json';
        my $text=$web || $format eq 'html' ? GP_RenderReport({title=>'GeoPresence',lead=>$data_error},1) : $data_error;
        return $unicodeEncoding ? $text : encode('UTF-8',$text);
    }
    if ($command eq 'debugTrace' && $format eq 'json' && defined $limit && @$value>$limit) {
        $value=[@$value[(@$value-$limit)..$#$value]];
    }
    if ($format eq 'json') {
        return GP_ReportJSON($value,$web);
    }
    my $report=GP_GetReport($hash,$command,\@positional,$value,$limit);
    my $text= $command eq 'locationCommands' && $format eq 'text' ? join("\n",@{$value->{commands}})
        : GP_RenderReport($report,$format eq 'html');
    # Explicit text in FHEMWEB still needs a safe, wrapping preformatted block.
    if ($web && $format eq 'text') {
        $text=join("\n",map {GP_ReportEscape($_)} split /\n/,$text);
        $text='<html><pre style="max-width:80vw;white-space:pre-wrap;overflow-wrap:anywhere">'.$text.'</pre></html>';
    }
    return $unicodeEncoding ? $text : encode('UTF-8',$text);
}

sub GP_GetData {
    my ($hash,$name,$command,@args)=@_;
    my $c=GP_Controller($hash);
    return (undef,'Controller unavailable') unless $c;
    if ($command eq 'logStatus') {
        return ({file=>GP_LogPath($c),verbose=>GP_Attr($c->{NAME},'verbose',GP_Attr('global','verbose',3)),
            debugLog=>GP_Attr($c->{NAME},'debugLog','auto'),normal_log=>'FHEM',
            debugEnabled=>length(GP_LogPath($c)) && GP_DebugLogEnabled($c,{mode=>'debug'}) ? 1:0,
            learningEnabled=>length(GP_LogPath($c)) && GP_DebugLogEnabled($c,{mode=>'learning'}) ? 1:0,
            activeEnabled=>length(GP_LogPath($c)) && GP_DebugLogEnabled($c,{mode=>'active'}) ? 1:0,
            error=>$c->{helper}{gp_log_error}//'',rate_limit=>300});
    }
    if ($command eq 'timerStats') {
        my $stats=$c->{helper}{gp_timer_stats}//{};
        my %view=map {$_=>$stats->{$_}//0} qw(runs slow_runs late_runs last_device_scans last_config_builds);
        $view{$_}=0+sprintf('%.3f',$stats->{$_}//0) for qw(last_ms max_ms last_lag_ms max_lag_ms last_started_at last_cpu_ms profile_started_at);
        $view{mean_ms}=0+sprintf('%.3f',($stats->{total_ms}//0)/($stats->{runs}||1));
        $view{$_}=GP_TimerSampleView($stats->{$_}) for qw(last_run worst_run worst_late_run);
        $view{$_}=[map {GP_TimerSampleView($_)} @{$stats->{$_}//[]}] for qw(recent_slow recent_late);
        return (\%view);
    }
    if ($command eq 'validate') {
        my @errors=GP_Validate($c,$args[0],0);
        return ({valid=>0,errors=>\@errors,warnings=>[]}) if @errors;
        my @res=defined($args[0]) ? ($args[0]) : GP_Residents($c);
        my @geometry;
        my @places;
        my @unused;
        for my $r (@res) {
            my $debug=GP_EffectiveMode($c,$r,0) ne 'active';
            my $cfg=GP_Config($c,$r,$debug);
            push @geometry,@{$cfg->{geometry_errors}};
            my @missing=grep {$cfg->{zones}{$_}{role} eq 'place'} GP_MissingGeometry($cfg);
            push @places,"$r: geometry not yet available for registered places: ".join(', ',@missing)
                .($debug ? '. Debug data; send Geofency test webhooks before testing.'
                    : '. Production data; confirm reviewed debug geometry with applyGeometry before activation, or wait for real Geofency observations.')
                .' Configuration remains valid.' if @missing;
            my @keys=grep {exists($attr{$r}{$_}) && !GP_ResidentAttrEnabled($cfg->{sourceMode},$_)} @{$GP_ATTRS{resident}};
            push @unused,"$r: ".join(', ',@keys)." not used by $cfg->{sourceMode}; remove unused attributes explicitly" if @keys;
            if ($cfg->{sourceMode} eq 'geofency_only') {
                my ($home)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{home}//[]};
                my ($outer)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{outer}//[]};
                push @unused,"$r: outer boundary is too close to Home for departure evidence; use a sufficiently distant location"
                    if GP_HasGeometry($home) && GP_HasGeometry($outer)
                        && $outer->{radius}-GP_Distance($outer,$home)-$home->{radius}<=$cfg->{departure_margin};
            }
        }
        return ({valid=>1,errors=>[],warnings=>[
            (@geometry ? 'Opening unavailable until geometry is ready: '.join('; ',@geometry):()),@places,@unused]});
    }
    if ($command eq 'learnedLocations' || $command eq 'locationCommands') {
        my ($r,$id,$role,$target)=@args;
        return (undef,'Specify a resident device') unless GP_Field($r,'SUBTYPE','') eq 'resident' && GP_Field($r,'CONTROLLER','') eq $c->{NAME};
        my $learned=GP_Learned($c,$r);
        return (undef,'No current learning data; use set resident mode learning and send an isTest=true webhook') unless $learned;
        return ([sort {$a->{number}<=>$b->{number}} values %{$learned->{zones}}]) if $command eq 'learnedLocations';
        return (undef,'Confirm learning with set resident learnConfirm before creating locations') unless $learned->{confirmed};
        return (undef,'Usage: get controller locationCommands resident zoneId-or-@number home|outer|approach|place newDeviceName')
            unless @args==4 && defined($id) && (GP_Id($id) || $id =~ /\A\@[1-9][0-9]?\z/)
                && defined($role) && $role =~ /\A(?:home|outer|approach|place)\z/ && GP_Name($target);
        if ($id =~ /\A\@(\d+)\z/) {
            my ($z)=grep {$_->{number}==$1} values %{$learned->{zones}};
            return (undef,'Learning number not found; see learnedLocations') unless $z;
            $id=$z->{id};
        }
        return (undef,'Location not observed for this resident; see learnedLocations') unless $learned->{zones}{lc $id};
        return (undef,'Device name already exists; choose a new name') if exists $defs{$target};
        return ({commands=>["define $target GeoPresence location $r $role","attr $target zoneId ".lc($id)]});
    }
    return (undef,'Unknown argument, choose one of '.GP_GetList($hash)) unless $command =~ /\A(?:debugTrace|explain)\z/;
    my $r=$args[0]//(($hash->{SUBTYPE}//'') eq 'resident' ? $name:'');
    return (undef,'Specify a resident device') unless GP_Field($r,'SUBTYPE','') eq 'resident' && GP_Field($r,'CONTROLLER','') eq $c->{NAME};
    my $rt=$c->{helper}{gp}//{};
    if ($command eq 'debugTrace') { return ((($rt->{debug}//{})->{$r}//{})->{trace}//[]); }
    my $mode=GP_EffectiveMode($c,$r,0);
    my $view=($args[1]//'prod') eq 'debug'?'debug':'production';
    my $debug=$view eq 'debug'; my $pool=$debug?'debug':'prod';
    my $s=($rt->{$pool}//{})->{$r};
    my $cfg=GP_Config($c,$r,$debug);
    my @errors=GP_Validate($c,$r,$mode eq 'active'?1:0,$cfg);
    my @blockers;
    if ($debug) {
        my $pending=keys %{$rt->{actors}//{}};
        for my $device (GP_DeviceNames($c)) {
            my $d=$defs{$device};
            if (($d->{ACTIONTYPE}//'') eq 'door_open') {
                $pending++ if GP_Read(GP_Attr($d->{NAME},'feedbackDevice',''),'pulse_state','') eq 'pending';
            } elsif (($d->{ACTIONTYPE}//'') eq 'garage_open') {
                $pending++ if GP_Read(GP_Attr($d->{NAME},'stateDevice',''),'state','') =~ /\A(?:movup|movdown)\z/;
            }
        }
        push @blockers,'Controller not ready' unless $rt->{ready};
        push @blockers,'Actuator operation in progress' if $pending;
        push @blockers,'Operating mode disabled' if $mode eq 'disabled';
        push @blockers,'Resident is learning; confirm setup before testing' if $mode eq 'learning';
        push @blockers,'Configuration invalid' if @errors;
    }
    return ({view=>$view,mode=>$mode,requested_mode=>GP_Mode($r),controller_mode=>GP_Mode($c->{NAME}),mode_reason=>GP_ModeReason($c,$r),
        resident=>$r,controller=>$c->{NAME},initialized=>$s?1:0,
        snapshot_at=>GP_Now()+($debug && $s?($s->{debug_offset}//0):0),
        sourceMode=>$cfg->{sourceMode},sources=>{geofency=>GP_UsesSource($cfg->{sourceMode},'geo')?1:0,
            phone=>GP_UsesSource($cfg->{sourceMode},'phone')?1:0},
        state=>$s//{},geometry=>$rt->{geometry}{$pool}{$r}//{},
        geometry_ready=>$cfg->{geometry_ready},geometry_errors=>$cfg->{geometry_errors},missing_geometry=>[GP_MissingGeometry($cfg)],
        ($debug?(debug_ready=>@blockers?0:1,debug_blockers=>\@blockers):()),
        test_webhook_isolation=>1,debug_reset_keep_geometry=>1,
        session_started_at=>$rt->{resident_start}{$r}//$rt->{start},pending_actors=>[sort keys %{$rt->{actors}//{}}],errors=>\@errors});
}

1;

=pod

=item device
=item summary Geofency and local phone presence with configurable arrival actions and isolated debugging

=begin html

<a id="GeoPresence"></a>
<h3>GeoPresence</h3>
<div>
  <p>GeoPresence updates ROOMMATE presence from Geofency webhooks, indoor phone sensors, or both. The default source profile geofency_phone combines both sources. Configurable rules request door or garage opening, send notifications, or switch on a device. A Home entry alone does not authorize opening: a confirmed departure and a valid return are required.</p>
  <h4>Device types</h4>
  <ul>
    <li><b>Controller:</b> webhook listener, shared timing and diagnostics.</li>
    <li><b>Resident:</b> one person, their phone sensors and ROOMMATE device.</li>
    <li><b>Location:</b> one Geofency zone belonging to a resident.</li>
    <li><b>Action:</b> the door, garage, notification or switch operation.</li>
    <li><b>Rule:</b> when an action applies and to which residents.</li>
  </ul>
  <p>Devices and rules are created explicitly. GeoPresence does not call the old Geo module or create configuration devices automatically.</p>
  <h4>Using FHEMWEB</h4>
  <p>Select an attribute on a device's detail page to display its English help below the input fields. Each description identifies the applicable device, accepted values, default or requirement, and an example.</p>
  <ul>
    <li>The selector shows only attributes for this device type and, for actions, this action type.</li>
    <li>Fixed values use dropdowns. Residents, locations and phone sensors use multiple selection; rules offer a dropdown for their action.</li>
    <li>Choose the value, then press <b>attr</b> to apply it. For multiple selection, click the value field, select devices and press <b>OK</b> first.</li>
    <li>Reload an open detail page after defining, deleting or renaming devices to see updated choices. With no available choices, references remain text fields.</li>
  </ul>
  <p>Existing references are not rewritten automatically; validation still reports missing devices. Standard attributes such as <code>alias</code>, <code>room</code> and <code>verbose</code> retain FHEM's framework help.</p>
  <p>Use <code>help GeoPresence EN</code> or <code>help System.GeoPresence EN</code> for this complete English reference.</p>

  <a id="GeoPresence-define"></a>
  <h4>Define</h4>
  <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">define &lt;name&gt; GeoPresence controller
define &lt;name&gt; GeoPresence resident &lt;controller&gt; &lt;ROOMMATE&gt;
define &lt;name&gt; GeoPresence location &lt;resident&gt; &lt;function&gt;
define &lt;name&gt; GeoPresence action &lt;controller&gt; &lt;actionType&gt;
define &lt;name&gt; GeoPresence rule &lt;controller&gt;</pre>
  <p>Only one controller is supported. Parent devices and the resident's ROOMMATE must already exist. Device names start with a letter and contain only letters, digits, underscores, dots or hyphens. New residents start disabled and can be configured while other residents operate. Changes to existing devices require all affected residents to be debug or disabled. Shared configuration requires pausing all affected residents or the controller. The location function and action type are part of the definition, not attributes.</p>
  <h5>Location functions</h5>
  <ul>
    <li><code>home</code>: the inner home circle. Required once for each Geofency resident.</li>
    <li><code>outer</code>: the surrounding circle, fully containing Home. Required once for each Geofency resident; an exit can confirm a remote trip.</li>
    <li><code>place</code>: an ordinary location, such as an office, garden or checkpoint. Use freely named groups to combine locations. A sufficiently distant circle can independently confirm departure.</li>
    <li><code>approach</code>: optional surrounding arrival context and motion evidence; no opening until confirmed Home or phone arrival.</li>
  </ul>
  <p>To change an existing location's function while keeping its zoneId and readings, use <code>modify Geo.PERSON.ORT location Geo.PERSON place</code> while all affected residents are debug or disabled. Its parent cannot be changed by modify. Validate before activation.</p>
  <h5>Action types</h5>
  <ul>
    <li><code>door_open</code>: request opening through an existing door controller with feedback.</li>
    <li><code>garage_open</code>: request opening through a relay, with garage state and end contacts.</li>
    <li><code>notify</code>: send a configured message through the installed <code>pushMsg</code> function.</li>
    <li><code>switch_on</code>: send a fixed <code>on</code> command to an ordinary load such as a light.</li>
  </ul>

  <a id="GeoPresence-setup"></a>
  <h4>Setup example: PERSON and a garden light</h4>
  <p>The example assumes that <code>rr_PERSON</code>, two PRESENCE sensors and <code>test.dev.licht</code> already exist. Replace the password placeholder; the phone identifier is learned from the first authenticated test webhook. If a controller already exists, use it instead of defining a second one.</p>
  <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">define System.GeoPresence GeoPresence controller
set System.GeoPresence mode debug
attr System.GeoPresence webhookPort 8090
attr System.GeoPresence logFile ./log/geopresence-%Y-%m.log
define Geo.PERSON GeoPresence resident System.GeoPresence rr_PERSON
attr Geo.PERSON webhookUser geo_person
attr Geo.PERSON phoneProxies Phone.PERSON.RAUM1,Phone.PERSON.RAUM2
attr Geo.PERSON phoneSignalMode state
set Geo.PERSON webhookPassword __RANDOM_PASSWORD__
set Geo.PERSON mode learning</pre>
  <p>Configure Geofency to POST to your HTTPS proxy URL ending in <code>/fhem/geopresence</code>, using the configured account and password. Use Geofency's entry or exit test buttons for Home, the outer home circle, and the garden; they send <code>isTest=true</code>. These one-shot tests do not create a visit or timeline entry and are not retried automatically. Keep this same URL for normal operation. Device identifier, geometry and zone IDs come from Geofency; do not enter them manually. Inspect the candidate, then confirm it with learnConfirm:</p>
  <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence learnedLocations Geo.PERSON
set Geo.PERSON learnConfirm
get System.GeoPresence learnedLocations Geo.PERSON
get System.GeoPresence locationCommands Geo.PERSON @1 home Geo.PERSON.Home
get System.GeoPresence locationCommands Geo.PERSON @2 outer Geo.PERSON.Outer
get System.GeoPresence locationCommands Geo.PERSON @3 place Geo.PERSON.Garden</pre>
  <p>Use the actual learning numbers or UUIDs from the returned list. Execute each returned define/attr pair yourself; locationCommands only displays text. Once the locations exist, connect the light to garden entry:</p>
  <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">define Geo.Action.GardenLight GeoPresence action System.GeoPresence switch_on
attr Geo.Action.GardenLight target test.dev.licht
attr Geo.Action.GardenLight command on
define Geo.Rule.PERSONGarden GeoPresence rule System.GeoPresence
attr Geo.Rule.PERSONGarden residents Geo.PERSON
attr Geo.Rule.PERSONGarden trigger enter
attr Geo.Rule.PERSONGarden locations Geo.PERSON.Garden
attr Geo.Rule.PERSONGarden action Geo.Action.GardenLight
get System.GeoPresence validate
get System.GeoPresence logStatus
set System.GeoPresence applyGeometry Geo.PERSON
set Geo.PERSON mode debug</pre>
  <p>Test in debug before activation. New or changed geometry cancels the previous trip, pending actions and phone absence qualification; no rules execute in that event batch. A fresh, consistent Home exit may start a new unconfirmed local trip after geometry validation. It needs new departure confirmation: a full new phone absence window after the exit or independent Geo distance evidence under the source profile's normal rules. A changed-geometry Home entry alone never grants opening permission. Diagnostics identify the location, original event time and changed values in <code>geometry_changes</code>.</p>
  <p>A duplicate Home or approach entry may fill missing motion while that arrival section is still current. It does not replay visits or rules, replace known motion, refresh the observation timestamp or restart the Home wait. Completed or interrupted arrivals are not reopened. Debug plans appear as <code>would execute; debug suppressed</code>. The light, door, garage, notifications and ROOMMATE are not changed by the simulation. Start with the German handbook <code>doc/GeoPresence_Handbuch.md</code> for a complete resident setup and examples of locations, actions and rules. The separate <code>doc/GeoPresence_Testanleitung.md</code> describes automated everyday tests and guided phone tests for custom actions and groups.</p>

  <a id="GeoPresence-operation"></a>
  <h4>Operation, transport and persistence</h4>
  <h5>Operating modes</h5>
  <p>Controller and residents default to <code>disabled</code>. Set their modes explicitly. Both must be active for productive actions. Either disabled blocks processing; resident learning captures setup data under an active or debug controller; otherwise either debug selects simulation.</p>
  <p>A POST with <code>isTest=true</code> selects learning while that resident is learning, otherwise simulation even with both devices active. There is one webhook URL for learning, tests and normal operation; child paths return 404. The case-sensitive form field <code>isTest</code> accepts true/1 for tests and false/0 for normal observations; an omitted field also means normal observation. Other values or duplicate fields are rejected. Disabled devices still reject test requests. The test marker applies to that request; real webhooks and phone observations continue according to the configured modes.</p>
  <p>Debug processing uses separate state, does not publish readings or FHEM events, and never calls the output adapters. Existing hardware operations already dispatched in production are still observed until completion. The separate operator command applyGeometry explicitly confirms reviewed location metadata in ordinary readings without promoting any simulated visit or permission.</p>
  <h5>Webhook access</h5>
  <p>Use an HTTPS reverse proxy for the dedicated HTTP listener. Forward only the exact path <code>/fhem/&lt;webhookPath&gt;</code> to webhookPort. Block all child paths with HTTP 404 so that child paths cannot fall through to a general FHEMWEB proxy. This listener is not FHEMWEB and provides no FHEM command endpoint. A proxy on another machine requires an explicit webhookBindAddress and webhookAllowedPeers.</p>
  <p>Webhooks require HTTP Basic authentication and <code>application/x-www-form-urlencoded</code> POST data containing Geofency's <code>device</code>, <code>id</code>, <code>entry</code> (0/1), <code>date</code>, <code>latitude</code>, <code>longitude</code> and <code>radius</code>. Optional motion selects the Home confirmation wait and can refine the garage decision. Unused metadata may contain line breaks and tabs; decision fields remain strict. Credentials and raw payloads are not logged.</p>
  <h5>Indoor phone presence</h5>
  <p>Indoor sensors are used only by geofency_phone and phone_only. In geofency_only, phone state and health are explicitly disabled; no sensors are polled, no phone simulation is accepted, and a lost Home webhook has no phone fallback.</p>
  <p>One detecting indoor sensor is enough for presence. Changing rooms or being seen by multiple sensors does not create another arrival. Absence requires all configured sensors to be negative for phone_absence_window. A short reception gap preserves presence and cannot authorize a new opening. Phone arrival can replace a missing Home webhook after a qualified trip. A local walk can authorize the door; the garage additionally needs driving evidence or a remote trip without fresh contradictory walking/running/cycling evidence.</p>
  <h5>Home arrival confirmation</h5>
  <p>If held indoor presence rejects an outer departure, an earlier unarmed local Home exit remains pending when it is newer than the last actual positive phone observation. Only complete phone absence qualification can authorize that trip; rejected distance or prior-exit evidence is not retained. A new Home entry or positive phone observation cancels the unarmed suspicion. Short reception gaps therefore cannot open either actor.</p>
  <p>A qualified Home entry is provisional (<code>returning</code>). Default confirmation waits:</p>
  <ul>
    <li><b>Walking or unknown:</b> 60 seconds.</li>
    <li><b>Running:</b> 30 seconds.</li>
    <li><b>Cycling:</b> 20 seconds.</li>
    <li><b>Automotive:</b> 10 seconds.</li>
  </ul>
  <p>The faster waits need motion observations at most 30 seconds old in the current arrival section. A new local phone arrival may confirm earlier.</p>
  <p>A received newer exit cancels the provisional return without consuming its trip; queued observations are evaluated before timer confirmation. The confirmed arrival creates at most one door request per trip, even if the phone is detected later.</p>
  <p>Missing or delayed exits cannot be excluded by a timer alone. The short car wait deliberately does not reject every 15-second false entry. A fresh walking veto cannot expire into garage permission during the intentional wait.</p>
  <h5>Activation and configuration changes</h5>
  <p>Production activation validates configuration and checks for conflicting legacy arrival paths. Set the ROOMMATE's rr_locationUnderway to underway, remove old rr_geofenceUUIDs and disable the old arrival handlers before activation. Resident and private-location configuration requires that resident to be effectively debug or disabled; shared changes require pausing all affected residents. Controller configuration requires controller debug or disabled. Changes revoke the affected journeys. Diagnostic settings debugLog, logFile and standard verbose can be changed during production without resetting trips or learning.</p>
  <h5>Persistence</h5>
  <p>Use FHEM's normal save mechanism for definitions, attributes and production readings. A deviceId confirmed with learnConfirm is an ordinary configuration attribute; learnConfirm does not call save. Production geometry is stored in gp_geometry. A qualified unfinished production trip is stored as one versioned gp_trip_checkpoint reading. After restart, rereadcfg or module reload it can resume if identity, configuration, geometry and the trip_resume_max_age limit still match and no later Home or indoor presence contradicts it. A NEW return is required; startup alone never opens, and old arrival timers, queued commands, unconfirmed departures and debug trips never resume. The checkpoint is consumed before dispatching opening commands. gp_resume_status/gp_resume_reason and explain describe restoration or rejection.</p>
  <p>Checkpoints use the ordinary FHEM state file; no additional database or automatic configuration save is used. A clean shutdown writes the state file; after an abrupt crash only the last successfully written state is available, so observations missed during downtime cannot be reconstructed. Test requests never promote debug geometry or permissions. Learning results for a configured phone remain available in the current process after learnConfirm or timeout; a restart, new learning session, phone identity change or resident deletion discards them. An unconfirmed phone candidate is also discarded by cancellation, relevant configuration/password changes or module reload.</p>

  <p>Productive resident readings <code>gp_arrival_pending</code>, <code>gp_arrival_motion</code>, <code>gp_arrival_wait</code> and <code>gp_arrival_deadline</code> show the provisional return (deadline in Unix seconds). Debug exposes the same information under <code>state.arrival</code> in <code>get System.GeoPresence explain Geo.PERSON debug format=json</code>. English diagnostics include <code>arrival pending</code>, <code>arrival cancelled</code> and <code>arrival confirmed</code>, with motion, wait and confirmation source. These details are written only to the separate diagnostic file.</p>
  <p><code>departure rejected; pending Home exit retained</code> distinguishes a retained unarmed Home exit from a rejected outer departure and includes phone state, health and the last positive observation time. The <code>departure_armed</code> field on <code>phone absence qualified</code> distinguishes a qualified trip (1) from status-only absence (0).</p>

  <a id="GeoPresence-set"></a>
  <h4>Set commands</h4>
  <p>Use set mode directly on a controller or resident. Learning and learnConfirm belong to the resident. Debug tools and applyGeometry belong to the controller and require an explicit resident argument. Learning needs controller active or debug; simulation tools are unavailable during learning. applyGeometry accepts effective debug or a disabled resident with confirmed learning data.</p>
  <p><b>FHEMWEB:</b> Open the controller detail page, choose an individual command in the set dropdown, then select its resident or resident/value combination and press <b>set</b>. Choices include residents with the relevant source profile. An empty selection executes nothing and returns usage instructions. For debugAdvance, enter the resident and seconds separated by a space, for example <code>Geo.PERSON 180</code>. The webhookPassword command is on the resident detail page instead. Complete commands can also be entered in the FHEMWEB command line or Telnet.</p>
  <ul>
    <li><a id="GeoPresence-set-webhookPassword"></a><b>webhookPassword &lt;password&gt;</b>
      <p><b>Applies to:</b> Resident only</p>
      <p>Store a salted password verifier in FHEM's key store. Use a random 24&ndash;128 character password containing only A&ndash;Z, a&ndash;z, 0&ndash;9, underscore or hyphen, and enter it in Geofency's HTTP Basic account settings.</p>
      <p>The affected resident must not be effectively active. Changing the password revokes only this resident's trips and captured learning data; other residents continue.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set Geo.PERSON webhookPassword &lt;new-random-password&gt;</pre>
    </li>
    <li><a id="GeoPresence-set-mode"></a><b>mode active|debug|disabled|learning</b>
      <p><b>Applies to:</b> Controller and resident. Both start disabled. Select mode in the device's set dropdown; it is an operating command, not an attribute. Controller choices are active, debug and disabled; Geofency residents additionally offer learning.</p>
      <ul>
        <li><b>active:</b> validate configuration and allow productive processing only when both controller and resident are active.</li>
        <li><b>debug:</b> simulate observations without productive ROOMMATE updates, device commands or messages. Controller debug overrides all active residents; an individual resident can debug while others remain active.</li>
        <li><b>disabled:</b> stop new processing. Controller disabled blocks every resident. Explicitly disabling a learning resident cancels its unconfirmed capture, including after a timeout.</li>
        <li><b>learning:</b> resident only, with controller active or debug. Open a 15-minute window for authenticated, fresh isTest=true webhooks, replacing the previous learning list. Configure the unique webhookUser and password first. No deviceId, locations or phone sensors are needed yet. Real observations are acknowledged and ignored; no phone polling, journeys or actions run for this resident.</li>
      </ul>
      <p>The first valid test pins the phone identifier if unconfigured; later tests must match it. At most 32 locations are captured. Use Geofency's entry/exit test buttons. After timeout the resident becomes disabled; data remain reviewable and can be explicitly confirmed. Learning never activates automatically. Repeating the current mode preserves state and does not extend the window; cancel before beginning a replacement window.</p>
      <p>Mode changes revoke the affected resident's journeys and queued observations. Individual changes preserve other residents and the listening socket. Controller changes affect all residents; switching between active and debug preserves open learning windows, while disabled cancels them. Already dispatched hardware remains observed. Failed activation leaves the previous mode intact.</p>
      <p>The mode reading is saved through normal FHEM state saving. Module reload retains current active/debug/disabled modes; restart or rereadcfg restores saved modes and their original timestamps after loading the configuration. Only devices without a saved mode default to disabled. effectiveMode and modeReason explain controller precedence. Learning becomes disabled and unconfirmed captures are discarded. Only a validated qualified production trip can resume; mode changes still revoke its checkpoint. Use save after setup; recovery after a crash uses the last successfully written state file. debugLog independently controls diagnostic output.</p>
      <p><b>Resident device status:</b> FHEMWEB and list show the effective mode as STATE: disabled, learning, debug or active. New residents show disabled. For example, an active resident shows debug while the controller is in debug mode. Confirmation or expiry of learning returns the display to disabled. This is the operating mode, not home/absent presence; presence belongs to the linked ROOMMATE. The display is recalculated after reload or restart and does not create events or actions.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set System.GeoPresence mode active
set Geo.PERSON mode learning
get System.GeoPresence learnedLocations Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-set-learnConfirm"></a><b>learnConfirm</b>
      <p><b>Applies to:</b> Geofency resident only. Explicitly confirm the captured phone and locations and close reception. A new deviceId is written using FHEM's standard attribute command; an existing identifier is never replaced. The resident remains disabled, including after a timed-out window. Repeating confirmation of already confirmed data changes nothing.</p>
      <p>No location devices, trips, ROOMMATE changes, messages or actuator commands are created. Use learnedLocations, execute the definition pairs from locationCommands, then applyGeometry to confirm reviewed metadata before testing. Empty or conflicting capture is rejected; use mode disabled to cancel. Confirmation does not call save.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set Geo.PERSON learnConfirm
get System.GeoPresence learnedLocations Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-set-applyGeometry"></a><b>applyGeometry &lt;resident&gt;</b>
      <p><b>FHEMWEB:</b> Select applyGeometry on the controller, select the resident in the adjacent dropdown and press set.</p>
      <p>Explicitly confirm the complete, reviewed debug geometry of this Geofency resident's registered locations for production. First send Geofency entry or exit test requests for missing or changed locations, wait for processing and inspect explain with debug. Every registered location needs valid geometry. After learnConfirm, matching captured geometry also supplies registered locations. A learning list alone creates no devices. Finish any learning window before applying.</p>
      <p>The resident must be effectively debug or individually disabled with confirmed learning data. The controller may remain active. Review the captured or simulated geometry first. Checks reject missing or conflicting geometry, incorrect phone/zone bindings, invalid circle nesting, synthetic debugAdvance time and any attempt to replace newer production geometry with older differing data. A failed check changes no readings.</p>
      <p>The command resets this resident's debug and productive trips and pending observations, then writes only new or changed geometry into normal gp_geometry readings. Original observation timestamps are retained. It emits no location events, userReadings/stateFormat callbacks, ROOMMATE changes, messages or actuator commands. Other residents and feedback tracking of existing actuator operations are unaffected. Unchanged production metadata is left intact.</p>
      <p>After confirmation, mode changes and reloads can load the geometry from the readings. Use FHEM's normal state saving for restart persistence; this command does not call save. New real departure and arrival evidence is still required for opening. The test application never calls this command.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence explain Geo.PERSON debug
set System.GeoPresence applyGeometry Geo.PERSON
set Geo.PERSON mode active
get System.GeoPresence validate Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-set-debugReset"></a><b>debugReset &lt;resident&gt; [keepGeometry]</b>
      <p><b>Applies to:</b> Controller only</p>
      <p>Discard this resident's debug trip, queued debug events, simulated geometry and clock offset. Reset the debug phone mode to live. Unavailable during learning or disabled operation; use the resident mode command to cancel learning. Confirmed setup results remain available.</p>
      <p>Add <code>keepGeometry</code> to keep the currently available debug geometry, including timestamps and conflict flags, while still discarding all travel history, pending arrivals and action plans. The automatic test application uses this option before scenarios and at cleanup so another invocation can reuse the same locations. Geometry stays in memory and is not written to productive readings. Mode/configuration changes, reloads, restarts and a reset without this option can still discard it.</p>
      <p><code>keepGeometry</code> requires a real-time debug session. After debugAdvance, use a full reset without this option and synchronize geometry again; synthetic timestamps must not carry over to real-time tests.</p>
      <p>Production state and devices are unchanged.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set System.GeoPresence debugReset Geo.PERSON keepGeometry</pre>
    </li>
    <li><a id="GeoPresence-set-debugPhoneMode"></a><b>debugPhoneMode &lt;resident&gt; live|simulated</b>
      <p><b>Applies to:</b> Controller only</p>
      <p>Choose real indoor sensors or isolated simulated phone observations for this resident's debug state. Requires geofency_phone or phone_only; unavailable in geofency_only. Reset the debug phone evaluation; after selecting simulated, explicitly set the desired value with debugPhone.</p>
      <p>Real PRESENCE devices are unchanged.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set System.GeoPresence debugPhoneMode Geo.PERSON simulated</pre>
    </li>
    <li><a id="GeoPresence-set-debugPhone"></a><b>debugPhone &lt;resident&gt; present|absent</b>
      <p>Controller only; requires a phone-enabled source profile and debugPhoneMode simulated. Supply this value to all simulated phone sources on following polls. Unavailable in geofency_only.</p>
      <p>Absence still needs the configured qualification time; this does not immediately set the resident absent.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set System.GeoPresence debugPhone Geo.PERSON absent</pre>
    </li>
    <li><a id="GeoPresence-set-debugAdvance"></a><b>debugAdvance &lt;resident&gt; &lt;seconds&gt;</b>
      <p>Controller only; requires simulated phone mode or geofency_only. Advance only the debug clock by an integer from 1 to 86400 seconds.</p>
      <p>Intended for controlled synthetic tests. Do not use during phone or automated everyday tests: their webhooks carry real event times.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set System.GeoPresence debugAdvance Geo.PERSON 180</pre>
    </li>
  </ul>

  <a id="GeoPresence-get"></a>
  <h4>Get commands</h4>
  <p>These commands return information without executing device definitions or actuator commands. The examples use the controller; debugTrace and explain also infer the resident when invoked on a resident device without a resident argument.</p>
  <p><b>Output formats:</b> FHEMWEB shows formatted reports; Telnet uses uppercase section headings, underlines, aligned values and indented entries. Prose wraps at about 80 columns; identifiers and commands are never cut. Append <code>format=json</code> for scripts, <code>format=text</code> for text in either interface, or <code>format=html</code> for HTML. Browser text is displayed in a safe, wrapping text block.</p>
  <p>JSON contains complete diagnostic data and Unix timestamps; errors use an <code>error</code> field. Reports are snapshots: reading them does not confirm arrivals, create a simulation, send commands or advance timers.</p>
  <ul>
    <li><a id="GeoPresence-get-validate"></a><b>validate [&lt;resident&gt;]</b>
      <p>Validate all configured residents, including disabled ones, or one named resident. Success starts with <code>OK: configuration valid</code>; findings identify the affected device. Missing Home, outer or configured approach geometry blocks opening; missing ordinary place geometry is reported as a notice without invalidating the configuration. The automatic test application also needs geometry for those places. With <code>format=json</code>, the result contains <code>valid</code>, <code>errors</code> and <code>warnings</code>.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence validate Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-get-learnedLocations"></a><b>learnedLocations &lt;resident&gt;</b>
      <p>Show the captured Device ID, its Binding (not configured or configured), reception status and a table of locations with learning number, name, zone ID, radius and local timestamp. While waiting for a new phone, the report explains that the first authenticated test webhook is required.</p>
      <p>Append <code>format=json</code> for the unchanged location array including coordinates; identity and reception status appear in the text/HTML report. Results for a configured phone survive learnConfirm, the reception timeout and module reloads in the same FHEM process. Unconfirmed candidates are discarded on a session reset. The location list itself is never saved as configuration.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence learnedLocations Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-get-locationCommands"></a><b>locationCommands &lt;resident&gt; &lt;zoneId-or-@number&gt; &lt;function&gt; &lt;newDeviceName&gt;</b>
      <p>Return a define command and zoneId attribute for a captured location; execute that output yourself. For a newly learned phone, confirm its deviceId with learnConfirm first. Select a UUID or learning number and function home, outer, place or optional approach. Use groups for freely named location categories.</p>
      <p>The target device must not already exist. Telnet returns only the commands, ready to copy; FHEMWEB shows them in a wrapping command block. With <code>format=json</code>, the result contains a <code>commands</code> array.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence locationCommands Geo.PERSON @1 home Geo.PERSON.Home</pre>
    </li>
    <li><a id="GeoPresence-get-debugTrace"></a><b>debugTrace &lt;resident&gt; [limit=&lt;count&gt;]</b>
      <p>Show the newest 20 recorded debug decisions first, even when file diagnostics are disabled. Use <code>limit=100</code> to see more; accepted counts are 1 to 1000. A <code>would execute; debug suppressed</code> entry describes an action plan, not a physical action or delivery confirmation.</p>
      <p>With <code>format=json</code>, the full retained history is returned in its original chronological order, unless an explicit limit selects only the newest entries.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence debugTrace Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-get-explain"></a><b>explain [&lt;resident&gt;] [prod|debug]</b>
      <p>Show the complete report for one resident with a prominent <b>=== DEBUG ===</b> or <b>=== PRODUCTION ===</b> banner. On the controller, a resident argument is required; on a resident device it can be omitted. Status shows Resident mode, Controller mode, Effective mode and Mode reason. These are independent of the selected report view. Selecting a report never changes that mode or processes events.</p>
      <ul>
        <li>No selector or <code>prod</code>: always inspect production, including when the resident is in debug mode. Paused processing and uninitialized states are labelled explicitly.</li>
        <li><code>debug</code>: inspect the isolated simulation, including test webhooks received while production is active.</li>
      </ul>
      <p><b>FHEMWEB:</b> Select explain and choose the resident from the dropdown, for example Geo.PERSON or Geo.PERSON debug. On a resident device, select prod or debug. All sections are included; lower sections are expandable. Telnet uses uppercase headings, underlines, aligned status values and one field per line, without inserting line breaks within a value.</p>
      <p><b>Geometry:</b> Opening checks cover Home, outer, configured approach and conflicts. Locations and geometry lists every radius and missing place. For missing geometry of a registered location, keep the resident in debug, send a fresh Geofency test and wait for processing. No new definition or mode learning is needed. Explicit applyGeometry confirms reviewed metadata before activation.</p>
      <p><b>Actions:</b> Eligibility does not mean a command was sent. Previous results and existing productive operations are labelled separately. Debug ready means simulation is available with no known ongoing actuator operation; it does not grant opening permission.</p>
      <p><b>Recent decisions:</b> Immediately below Status, initially expanded in FHEMWEB and collapsible by clicking its heading. Arrival actions starts collapsed. Rule / source identifies the rule, location, observation source or actuator target recorded for that decision. Not recorded means that the stored entry has no such information; a later observation is never substituted.</p>
      <p><b>JSON:</b> format=json returns the complete selected state. Fields include view (production or debug), mode (effective), requested_mode, controller_mode, mode_reason, initialized, state, geometry, geometry_ready, geometry_errors, missing_geometry, pending_actors and errors. The debug view also includes debug_ready and debug_blockers. Module capabilities test_webhook_isolation and debug_reset_keep_geometry remain available to the test application. To compare production and simulation, query each separately.</p>
      <p><b>Examples:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence explain Geo.PERSON
get System.GeoPresence explain Geo.PERSON debug
get System.GeoPresence explain Geo.PERSON prod
get System.GeoPresence explain Geo.PERSON debug format=json
get Geo.PERSON explain debug</pre>
    </li>
    <li><a id="GeoPresence-get-logStatus"></a><b>logStatus</b>
      <p>Show the normal log destination, diagnostic file, verbosity, diagnostic setting, separate simulation/learning/production output flags, rate limit and last write error. Enabled flags describe configured output, not verified write permissions. Append <code>format=json</code> for fields <code>debugEnabled</code>, <code>learningEnabled</code> and <code>activeEnabled</code>.</p>
      <p>Normal output goes to FHEM; detailed diagnostics go only to logFile.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence logStatus</pre>
    </li>
    <li><a id="GeoPresence-get-timerStats"></a><b>timerStats</b>
      <p>Show timer work, delayed starts and counters in separate sections, with millisecond units and a readable local start time. A Freezemon candidate is not proof of causation: GeoPresence may simply be waiting for another FHEM callback to finish. Millisecond statistics include synchronous callbacks and remain in memory until controller deletion or FHEM restart.</p>
      <p>With <code>format=json</code>, the original fields are retained: <code>runs</code>, <code>slow_runs</code>, <code>last_ms</code>, <code>mean_ms</code>, <code>max_ms</code> and per-callback device/configuration counts. <code>last_lag_ms</code>, <code>max_lag_ms</code> and <code>late_runs</code> measure delayed starts separately from the timer's own work; <code>last_started_at</code> is Unix time.</p>
      <p>Passive profiling also records the slowest measured run, its time, device and processing phases. <code>actor_command</code> includes the actuator's synchronous FHEM callbacks; <code>roommate_command</code> includes ROOMMATE callbacks; <code>resident_reading_callbacks</code> and <code>geometry_reading_callbacks</code> include notifications and userReadings caused by those updates. <code>diagnostic_file</code> measures file open/write/close; <code>normal_log</code> measures FHEM logging. No action behavior, polling interval or operating mode is changed.</p>
      <p>Phase <b>Elapsed</b> includes nested measured calls; <b>Self</b> excludes them. Do not add inclusive phase times. Process CPU time is approximate and has platform-dependent resolution. A low CPU value can accompany I/O waiting or OS scheduling delays; it does not identify the wait by itself.</p>
      <p><code>last_run</code>, <code>worst_run</code> and <code>worst_late_run</code> contain full phase breakdowns in JSON; <code>recent_slow</code> and <code>recent_late</code> retain up to twelve runs of at least 500 ms each. The readable report shows the largest six self-time totals of the slowest profiled run and the newest five entries of each history. Profiling is independent of debugLog and creates no readings or events. <code>profile_started_at</code> marks the beginning of available detail; older aggregate maxima may have no breakdown.</p>
      <p>Work of at least 500 ms produces a rate-limited <code>timer_slow</code> diagnostic in the separate diagnostic file when debugLog permits it. This names the largest measured phase and target; its own write is included in the final in-memory timerStats measurement. Use FHEM's <code>apptime max top</code> and <code>apptime maxDly top</code> to investigate other callbacks. In apptime, TS Max call is the time of the longest execution, not the largest start delay.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence timerStats</pre>
    </li>
  </ul>

  <a id="GeoPresence-attr"></a>
  <h4>Attributes</h4>
  <p>Comma-separated lists must not contain spaces. References are FHEM device names, not aliases or Geofency display names. Unless stated otherwise, changing configuration requires all affected residents to be debug or disabled and resets only their runtime sessions. Controller-wide settings require controller debug or disabled. Shared rule/action changes include previous and proposed residents and shared physical targets. New inactive residents and their private devices can be configured while others are active. Defaults apply when an attribute is absent.</p>
  <h5>Controller: operation, listener and diagnostics</h5>
  <ul>
    <li><a id="GeoPresence-attr-webhookPath"></a><b>webhookPath</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>geopresence</code></p>
      <p>A single path component beginning with a letter, followed by letters, digits, underscores or hyphens; no slashes. Creates only /fhem/&lt;value&gt;. The isTest form field selects test processing; there is no separate test URL.</p>
      <p>Use the same exact path in Geofency and the reverse proxy.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence webhookPath geopresence</pre>
    </li>
    <li><a id="GeoPresence-attr-webhookPort"></a><b>webhookPort</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Requirement:</b> Required; no default</p>
      <p>Integer 1024&ndash;65535 for the module's own HTTP listener, separate from FHEMWEB. Forward the two webhook paths from your HTTPS proxy to this port.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence webhookPort 8090</pre>
    </li>
    <li><a id="GeoPresence-attr-webhookBindAddress"></a><b>webhookBindAddress</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>127.0.0.1</code></p>
      <p>A concrete local IPv4 address; hostnames and wildcard 0.0.0.0 are rejected. Loopback works for a proxy on the same host.</p>
      <p>For the separate gateway in this installation, use the FHEM host's LAN address and explicitly configure webhookAllowedPeers.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence webhookBindAddress 192.0.2.20</pre>
    </li>
    <li><a id="GeoPresence-attr-webhookAllowedPeers"></a><b>webhookAllowedPeers</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>127.0.0.1</code><br>
      <b>Note:</b> must be explicitly set when binding outside loopback</p>
      <p>A comma-separated list of 1&ndash;16 distinct IPv4 addresses allowed to connect. Use the immediate TCP peer, usually the reverse proxy, not the iPhone or an X-Forwarded-For address.</p>
      <p>This does not replace webhook authentication.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence webhookAllowedPeers 192.0.2.10</pre>
    </li>
    <li><a id="GeoPresence-attr-logFile"></a><b>logFile</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Note:</b> No default file; without this attribute no diagnostic file is written</p>
      <p>Local filename ending in .log or .txt, at most 512 characters, using letters, digits, underscore, dot, slash, plus, hyphen and the date patterns %Y, %m, %d, %H, %M. Relative paths use FHEM's working directory; the parent directory must already exist and be writable.</p>
      <p>All diagnostic levels go exclusively here, independently of verbose, when debugLog enables them. At most 300 entries plus one suppression notice per minute; no credentials or raw payloads.</p>
      <p>File errors appear in logStatus and produce at most one short FHEM warning per minute, never a diagnostic fallback. Changing this attribute does not reset a trip or learning.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence logFile ./log/geopresence-%Y-%m.log</pre>
    </li>
    <li><a id="GeoPresence-attr-debugLog"></a><b>debugLog</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Values:</b> <code>auto</code>, <code>0</code>, <code>1</code><br>
      <b>Default:</b> <code>auto</code></p>
      <p>auto writes diagnostics for learning and debug processing, including an individual resident or a webhook marked isTest=true. 1 also writes detailed diagnostics during production; 0 disables file diagnostics. Requires logFile.</p>
      <p>This controls logging only: it does not change operating modes or permit/suppress actions. Changes do not reset trips or learning.</p>
      <p>Normal English action messages remain in FHEM's log, controlled by verbose (3 for actions, 2 for operational errors, 1 for file warnings).</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence debugLog 1</pre>
    </li>
  </ul>
  <h5>Controller: timing and distance</h5>
  <p>These controller settings apply to all its residents. Values must be positive; decimals are accepted. Arrival confirmation settings are limited to 300 seconds, other values to 172800. Values are seconds except departure_margin, which is metres.</p>
  <ul>
    <li><a id="GeoPresence-attr-action_max_age"></a><b>action_max_age</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>90</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Maximum age of an observation for current decisions and action dispatch. Delayed retries cannot perform an old opening.</p>
      <p>This limits observations, not the lifetime of an otherwise valid remote trip.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence action_max_age 90</pre>
    </li>
    <li><a id="GeoPresence-attr-future_tolerance"></a><b>future_tolerance</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>30</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Allowed event-time lead over the server clock and tolerance for clock discontinuities. Also defines the start boundary before new Geo evidence can qualify after session reset; old observations must not reactivate a saved trip.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence future_tolerance 30</pre>
    </li>
    <li><a id="GeoPresence-attr-reorder_window"></a><b>reorder_window</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>2</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Buffer incoming observations briefly before evaluating them in event-time order and checking conflicts. Larger values increase response latency.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence reorder_window 2</pre>
    </li>
    <li><a id="GeoPresence-attr-departure_grace"></a><b>departure_grace</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>60</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Delay after Home exit before absence can be displayed if the phone is not still considered present. This timer alone never grants return-opening permission.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence departure_grace 60</pre>
    </li>
    <li><a id="GeoPresence-attr-minimum_away"></a><b>minimum_away</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>60</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Minimum elapsed absence before a qualified return can open. Both event times and elapsed runtime must satisfy it; a quick boundary bounce does not authorize opening.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence minimum_away 60</pre>
    </li>
    <li><a id="GeoPresence-attr-phone_absence_window"></a><b>phone_absence_window</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>180</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Require every configured phone sensor to remain negative for this interval. Also retain presence as present/handover during a shorter reception gap; a room change must not create a new opening permission.</p>
      <p>Sensor errors interrupt qualification.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence phone_absence_window 180</pre>
    </li>
    <li><a id="GeoPresence-attr-phone_poll"></a><b>phone_poll</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>5</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Interval between evaluations of the existing phone sensor readings. Polling does not start a sensor scan or create a new real measurement.</p>
      <p>Processing occurs on the module's timer.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence phone_poll 5</pre>
    </li>
    <li><a id="GeoPresence-attr-motion_max_age"></a><b>motion_max_age</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>180</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Validity of usable motion evidence within the arrival context. Automotive evidence can qualify the garage; fresh walking, running or cycling without current automotive evidence suppresses it.</p>
      <p>Missing motion does not erase a still-fresh useful observation.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence motion_max_age 180</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_wait_walking"></a><b>arrival_wait_walking</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>60</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Home return confirmation wait measured from receipt of the first accepted entry, after an already qualified departure. Walking evidence may be retained for motion_max_age; missing motion does not erase it.</p>
      <p>A newer exit cancels the wait; a new local phone arrival can finish it early. Repeated entries do not restart it.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_wait_walking 60</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_wait_running"></a><b>arrival_wait_running</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>30</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Home return confirmation wait measured from receipt of the first accepted entry, after an already qualified departure. Requires running evidence no older than arrival_motion_max_age.</p>
      <p>A newer exit cancels the wait; a new local phone arrival can finish it early. Repeated entries do not restart it.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_wait_running 30</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_wait_cycling"></a><b>arrival_wait_cycling</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>20</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Home return confirmation wait measured from receipt of the first accepted entry, after an already qualified departure. Requires cycling evidence no older than arrival_motion_max_age.</p>
      <p>A short wait does not itself grant garage permission. A newer exit cancels the wait; a new local phone arrival can finish it early.</p>
      <p>Repeated entries do not restart it.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_wait_cycling 20</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_wait_automotive"></a><b>arrival_wait_automotive</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>10</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Home return confirmation wait measured from receipt of the first accepted entry, after an already qualified departure. Requires automotive evidence no older than arrival_motion_max_age.</p>
      <p>This is a comfort compromise: a false entry lasting longer than the wait can still open. A newer exit cancels the wait; a new local phone arrival can finish it early.</p>
      <p>Repeated entries do not restart it.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_wait_automotive 10</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_wait_unknown"></a><b>arrival_wait_unknown</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>60</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Home return confirmation wait measured from receipt of the first accepted entry, after an already qualified departure. Used without usable motion evidence, including stationary alone or expired fast-motion evidence.</p>
      <p>A newer exit cancels the wait; a new local phone arrival can finish it early. Repeated entries do not restart it.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_wait_unknown 60</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_motion_max_age"></a><b>arrival_motion_max_age</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>30</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Maximum age of running, cycling or automotive observations when selecting a faster Home confirmation wait. Only evidence from the current arrival section qualifies.</p>
      <p>This is independent of motion_max_age for garage decisions; it is the webhook observation age, not an independently measured activity confidence.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_motion_max_age 30</pre>
    </li>
    <li><a id="GeoPresence-attr-approach_timeout"></a><b>approach_timeout</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>600</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Lifetime of the optional approach context. Has no effect without an approach location; an approach location is not needed for the standard setup and cannot request opening.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence approach_timeout 600</pre>
    </li>
    <li><a id="GeoPresence-attr-zone_display_max_age"></a><b>zone_display_max_age</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>43200</code> seconds (12 hours)<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Expire old zone observations for display. Explicit group membership and prior-exit evidence do not arise from display expiry; a missing exit stays missing. This does not end a confirmed remote trip or trigger an opening.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence zone_display_max_age 43200</pre>
    </li>
    <li><a id="GeoPresence-attr-actor_timeout"></a><b>actor_timeout</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>60</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Wait for completion feedback after a productive door/garage command. Missing confirmation produces uncertain and releases the reservation; it does not automatically resend an opening pulse.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence actor_timeout 60</pre>
    </li>
    <li><a id="GeoPresence-attr-trip_resume_max_age"></a><b>trip_resume_max_age</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>172800</code> seconds (48 hours)<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Maximum age of the original confirmed departure when restoring a qualified trip after restart, rereadcfg or module reload. Checkpoints retain the original evidence time; saving or restarting does not renew it. The limit applies to recovery, not to uninterrupted trips in one running process. Expired or changed checkpoints are rejected without actions.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence trip_resume_max_age 172800</pre>
    </li>
    <li><a id="GeoPresence-attr-departure_margin"></a><b>departure_margin</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>200</code> metres<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Required clearance between Home and the edge of a distant location's circle for that location to prove departure. This is a distance threshold, not a second copy of a Geofency radius or a new zone to create.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence departure_margin 200</pre>
    </li>
  </ul>
  <h5>Resident</h5>
  <ul>
    <li><a id="GeoPresence-attr-sourceMode"></a><b>sourceMode</b>
      <p><b>Applies to:</b> Resident<br>
      <b>Values:</b> <code>geofency_phone</code>, <code>geofency_only</code>, <code>phone_only</code><br>
      <b>Default:</b> <code>geofency_phone</code></p>
      <ul>
        <li><code>geofency_phone</code>: authenticated Geo evidence plus indoor sensors, local contradiction checks and phone fallback. Requires Home/outer locations and phoneProxies. This remains the default for existing installations.</li>
        <li><code>geofency_only</code>: authenticated Geo evidence without indoor sensors. Requires Home/outer locations. Opening additionally needs a distant Geo observation, such as an outer exit or a sufficiently distant checkpoint; Home exit, motion and elapsed time alone do not qualify. There is no phone fallback or early phone confirmation.</li>
        <li><code>phone_only</code>: presence from indoor sensors. Requires phoneProxies, no Geo identity, password or locations. No Geo webhooks, learning or automatic opening.</li>
      </ul>
      <p>FHEMWEB offers the attributes relevant to the selected profile. Phone-only residents have no Geo credential or opening-permission controls. Stored inactive settings are not evaluated; validate lists them for explicit deletion. Changing the profile requires this resident to be effectively debug or disabled and resets trips, pending arrivals and learning reception.</p>
      <p>For geofency_only, a distant circle must be more than departure_margin away from the Home boundary. An enclosing circle proves distance on exit only if even its nearest boundary has this clearance. Identical Home/outer boundaries do not qualify. Normal minimum-away and motion-dependent return waits still apply; common GPS errors cannot be ruled out by Geo evidence alone.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON sourceMode geofency_phone</pre>
    </li>
    <li><a id="GeoPresence-attr-deviceId"></a><b>deviceId</b>
      <p><b>Applies to:</b> Resident<br>
      <b>Requirement:</b> Required for normal geofency_phone and geofency_only operation; leave unset when enrolling a new phone</p>
      <p>The Geofency phone identifier in the webhook's device field, not an FHEM name or zone UUID. Must be unique among residents.</p>
      <p>Use mode learning, send a test webhook and confirm with learnConfirm to set this attribute automatically. You do not need to find or copy the identifier in the app. An existing value is never overwritten by learning. Use FHEM save after setup to persist the confirmed attribute.</p>
      <p>Identifiers contain 1&ndash;128 ASCII letters/digits/underscores/dots/hyphens, starting with a letter or digit; comparison is case-insensitive. Changing the identity discards its learning results.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set Geo.PERSON mode learning</pre>
    </li>
    <li><a id="GeoPresence-attr-webhookUser"></a><b>webhookUser</b>
      <p><b>Applies to:</b> Resident<br>
      <b>Requirement:</b> Required for geofency_phone and geofency_only; no default</p>
      <p>Unique HTTP Basic username; enter exactly the same spelling in Geofency. Use 1&ndash;128 ASCII letters/digits/underscores/dots/hyphens, starting with a letter or digit.</p>
      <p>Configure its password with set webhookPassword, not an attribute.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON webhookUser geo_person</pre>
    </li>
    <li><a id="GeoPresence-attr-phoneProxies"></a><b>phoneProxies</b>
      <p><b>Applies to:</b> Resident<br>
      <b>Requirement:</b> Required for geofency_phone and phone_only: a non-empty, comma-separated list of distinct existing PRESENCE devices; no default. Unused in geofency_only.</p>
      <p>Use the multiple-selection dialog to choose existing devices. List all indoor sensors for this phone, without spaces. These are the phone sources evaluated by GeoPresence; no separate aggregation device is required.</p>
      <p>Any positive sensor means presence; absence requires every listed sensor to be negative throughout phone_absence_window. Simultaneous detection and handover between rooms count as continuous presence.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON phoneProxies Phone.PERSON.RAUM1,Phone.PERSON.RAUM2</pre>
    </li>
    <li><a id="GeoPresence-attr-phoneSignalMode"></a><b>phoneSignalMode</b>
      <p><b>Applies to:</b> Resident with geofency_phone or phone_only; unused in geofency_only<br>
      <b>Values:</b> <code>state</code>, <code>measurement</code><br>
      <b>Default:</b> <code>state</code></p>
      <ul>
        <li><code>state</code>: retain each sensor value until a change or detected error. Use this for sensors that report only changes.</li>
        <li><code>measurement</code>: require repeated fresh measurements from every sensor. Freshness is twice the longer sensor interval plus 30 seconds.</li>
      </ul>
      <p>An explicit failure interrupts absence qualification.</p>
      <p>A silent unreported sensor failure cannot be detected reliably from held state alone.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON phoneSignalMode state</pre>
    </li>
    <li><a id="GeoPresence-attr-allowDoor"></a><b>allowDoor</b>
      <p><b>Applies to:</b> Resident with geofency_phone or geofency_only<br>
      <b>Values:</b> <code>0</code>, <code>1</code><br>
      <b>Default:</b> <code>0</code></p>
      <p>Permit door-opening plans for this person. Requires a matching door rule and a qualified return; setting 1 alone neither opens nor bypasses departure checks.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON allowDoor 1</pre>
    </li>
    <li><a id="GeoPresence-attr-allowGarage"></a><b>allowGarage</b>
      <p><b>Applies to:</b> Resident with geofency_phone or geofency_only<br>
      <b>Values:</b> <code>0</code>, <code>1</code><br>
      <b>Default:</b> <code>0</code></p>
      <p>Permit garage-opening plans for this person, in addition to a matching rule and garage eligibility. Keep 0 for a person who should receive only door opening, even if a shared rule accidentally includes them.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON allowGarage 0</pre>
    </li>
  </ul>
  <h5>Location</h5>
  <ul>
    <li><a id="GeoPresence-attr-zoneId"></a><b>zoneId</b>
      <p><b>Applies to:</b> Location<br>
      <b>Requirement:</b> Required; no default</p>
      <p>The location identifier from Geofency's id field, usually a UUID, unique within this resident. Obtain it with learnedLocations/locationCommands; do not use the display name, radius, phone ID or learning number as this value.</p>
      <p>Use 1&ndash;128 ASCII letters/digits/underscores/dots/hyphens, starting with a letter or digit; comparison is case-insensitive. Geometry comes automatically from authenticated webhooks.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON.Home zoneId 01234567-89ab-cdef-0123-456789abcdef</pre>
    </li>
    <li><a id="GeoPresence-attr-label"></a><b>label</b>
      <p><b>Applies to:</b> Location<br>
      <b>Default:</b> the device name for place, otherwise the function name</p>
      <p>Human-readable location name used in GeoPresence state and logs; does not change the zone ID, function, groups or rule matching. Use a single-line text without semicolons.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON.Garden label Front garden</pre>
    </li>
    <li><a id="GeoPresence-attr-groups"></a><b>groups</b>
      <p><b>Applies to:</b> Location<br><b>Default:</b> unset<br><b>Values:</b> 1..16 distinct case-sensitive group names separated by commas without spaces</p>
      <p>Assign freely named tags such as Offices or Sport. Each name starts with a letter and contains at most 64 letters, digits, dots, underscores or hyphens. Groups are resident-local; the same tag on several residents supports shared rules without merging their presence. This attribute does not change the location's system function or geometric departure evidence.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON.ORT groups Offices</pre>
    </li>
  </ul>
  <h5>Action</h5>
  <ul>
    <li><a id="GeoPresence-attr-target"></a><b>target</b>
      <p><b>Applies to:</b> Action of type door_open, garage_open or switch_on<br>
      <b>Requirement:</b> Required existing FHEM device name; no default</p>
      <p>Receives the fixed command configured below. Conflicting switch/door/garage definitions for the same target are rejected. notify uses pushMsg and needs no target.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.GardenLight target test.dev.licht</pre>
    </li>
    <li><a id="GeoPresence-attr-command"></a><b>command</b>
      <p><b>Applies to:</b> Action<br>
      <b>Values:</b> <code>lock unlocked</code> for door_open; <code>on</code> for garage_open and switch_on<br>
      <b>Default:</b> None; required for these action types</p>
      <p>Only these fixed commands are supported. Do not include set, the target device, a command chain or a Perl expression. notify needs no command.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.GardenLight command on</pre>
    </li>
    <li><a id="GeoPresence-attr-contact"></a><b>contact</b>
      <p><b>Applies to:</b> door_open action<br>
      <b>Requirement:</b> Required existing door contact device; no default</p>
      <p>Its state reading must report closed or open. With the default positionSignalMode=state, an unchanged saved contact remains valid until a change or reported fault. Measurement mode requires a post-session reading. A closed door can receive an opening request; an open or unknown door does not receive another pulse.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Door contact Door.Contact</pre>
    </li>
    <li><a id="GeoPresence-attr-feedbackDevice"></a><b>feedbackDevice</b>
      <p><b>Applies to:</b> door_open action<br>
      <b>Requirement:</b> Required existing device exposing the door controller's pulse_state reading; no default</p>
      <p>pending means a pulse is running; a new confirmed, failed or cancelled event completes its reservation. A later idle does not erase that completion.</p>
      <p>Confirmation proves the pulse, not physical opening.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Door feedbackDevice Door.Controller</pre>
    </li>
    <li><a id="GeoPresence-attr-stateDevice"></a><b>stateDevice</b>
      <p><b>Applies to:</b> garage_open action<br>
      <b>Requirement:</b> Required existing garage state device; no default</p>
      <p>Its state reading uses off (closed), on (open), movup (opening) and movdown (closing). Opening also requires consistent upper/lower contacts under the selected positionSignalMode.</p>
      <p>Unknown, inconsistent or closing states do not receive a new impulse.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Garage stateDevice Garage.State</pre>
    </li>
    <li><a id="GeoPresence-attr-upperContact"></a><b>upperContact</b>
      <p><b>Applies to:</b> garage_open action<br>
      <b>Requirement:</b> Required existing upper end-contact device; no default</p>
      <p>state must be closed at the fully open end position and open otherwise. With garage state off, this contact must be open and lowerContact closed to authorize an opening pulse.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Garage upperContact Garage.Upper</pre>
    </li>
    <li><a id="GeoPresence-attr-lowerContact"></a><b>lowerContact</b>
      <p><b>Applies to:</b> garage_open action<br>
      <b>Requirement:</b> Required existing lower end-contact device; no default</p>
      <p>state must be closed at the fully closed end position and open otherwise. Both contacts closed is inconsistent; both open is a moving/intermediate position and does not qualify as closed.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Garage lowerContact Garage.Lower</pre>
    </li>
    <li><a id="GeoPresence-attr-positionSignalMode"></a><b>positionSignalMode</b>
      <p><b>Applies to:</b> door_open and garage_open actions<br>
      <b>Values:</b> <code>state</code>, <code>measurement</code><br>
      <b>Default:</b> <code>state</code></p>
      <p>state uses latched contact/position readings: a value remains valid across restart until changed or a detectable device/IO fault occurs. The sources must report transitions and reconcile their physical state after outages. Unknown values, future timestamps, disabled sources, reported disconnection and inconsistent garage contacts block commands. An unreported sensor outage cannot be detected from an unchanged reading alone.</p>
      <p>measurement requires every position source to have reported after the controller session began. Use it when your source guarantees repeated measurements or startup refreshes. Completion feedback after a command always needs a new update/event belonging to that request, independently of this option.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Door positionSignalMode state</pre>
    </li>
    <li><a id="GeoPresence-attr-message"></a><b>message</b>
      <p><b>Applies to:</b> notify action<br>
      <b>Requirement:</b> Required non-empty configured text, at most 500 characters both before and after substitution; no default</p>
      <p><code>%resident%</code> expands to the ROOMMATE alias or device name. Control characters, semicolons, braces and backslashes are forbidden.</p>
      <p>No free-form webhook text is executed. Production logs include the configured message; debug records only its planned rule/action.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Work message %resident% arrived at work.</pre>
    </li>
    <li><a id="GeoPresence-attr-priority"></a><b>priority</b>
      <p><b>Applies to:</b> notify action<br>
      <b>Values:</b> <code>0</code> (default, information), <code>1</code> (warning), <code>2</code> (error)</p>
      <p>Passed to the installed pushMsg function; that function determines delivery and speech behaviour. No pushMsg call is made in debug.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Work priority 0</pre>
    </li>
    <li><a id="GeoPresence-attr-channel"></a><b>channel</b>
      <p><b>Applies to:</b> notify action<br>
      <b>Values:</b> <code>0</code>, <code>1</code>, <code>2</code>, <code>10</code><br>
      <b>Default:</b> <code>0</code></p>
      <p>The channel is passed to the installed pushMsg function. GeoPresence does not assign these numbers to a delivery service; destinations and optional speech depend on that function's configuration.</p>
      <p>Debug suppresses the entire call.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Work channel 0</pre>
    </li>
  </ul>
  <h5>Rule</h5>
  <ul>
    <li><a id="GeoPresence-attr-enabled"></a><b>enabled</b>
      <p><b>Applies to:</b> Rule<br>
      <b>Values:</b> <code>1</code>, <code>0</code><br>
      <b>Default:</b> <code>1</code></p>
      <p>Include or exclude this rule from evaluation. Changing a shared rule requires all previously and newly selected residents to be debug or disabled and resets their sessions. Other residents can remain active.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.PERSONGarden enabled 1</pre>
    </li>
    <li><a id="GeoPresence-attr-trigger"></a><b>trigger</b>
      <p><b>Applies to:</b> Rule<br><b>Values:</b> arrival, enter, exit<br><b>Requirement:</b> Required</p>
      <ul><li><code>enter</code>/<code>exit</code>: an accepted observation of a selected location, or the first entry / last exit of a selected group.</li><li><code>arrival</code>: a confirmed return after a qualified trip, including the configured motion-dependent wait or phone confirmation. A startup Home observation is not sufficient.</li></ul>
      <p>Opening actions require arrival. Ordinary switch_on and notify actions may use any of these triggers. An enter rule at Home does not wait for arrival confirmation. FHEMWEB shows selectors for enter/exit and arrivalFilter for arrival; remove inapplicable stored selectors explicitly before changing the trigger.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.ORT trigger enter</pre>
    </li>
    <li><a id="GeoPresence-attr-residents"></a><b>residents</b>
      <p><b>Applies to:</b> Rule<br>
      <b>Selection:</b> One or more GeoPresence residents of this controller<br>
      <b>Requirement:</b> A non-empty resident list for every enabled rule</p>
      <p>Use the multiple-selection dialog to choose existing devices. Comma-separated existing GeoPresence resident names from the same controller, without spaces.</p>
      <p>Setting this attribute replaces the entire list. Keep all existing residents when extending a shared rule.</p>
      <p>Use Geo.PERSON, not rr_PERSON or an alias.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.Work residents Geo.PERSON,Geo.PERSON2</pre>
    </li>
    <li><a id="GeoPresence-attr-locationGroup"></a><b>locationGroup</b>
      <p><b>Applies to:</b> Rule with trigger enter or exit<br><b>Requirement:</b> Either one group or locations; not both</p>
      <p>A freely named location group, evaluated separately for each selected resident. Each resident must have at least one location carrying this tag in its groups attribute. Entry means first entered member; exit means the last explicitly entered member has left. Unknown members need not first be entered. Missing exits, geometry-based position inference and display expiry never generate a group exit.</p>
      <p>Use the same group tag on different residents' locations for a shared rule. Names are case-sensitive, start with a letter and contain up to 64 letters, digits, underscores, dots or hyphens. This filter is independent of FHEM's standard group attribute for display grouping.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.OfficeEntry locationGroup Offices</pre>
    </li>
    <li><a id="GeoPresence-attr-locations"></a><b>locations</b>
      <p><b>Applies to:</b> Rule with trigger enter or exit<br><b>Requirement:</b> Either a comma-separated location list or locationGroup; not both</p>
      <p>Match individual location events. A list is not a combined group: entering either listed location can trigger independently. Every selected location must belong to a resident in the rule, and each selected resident needs at least one matching location. The multiple-selection widget offers registered locations of this controller.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.ORT locations Geo.PERSON.ORT</pre>
    </li>
    <li><a id="GeoPresence-attr-afterExit"></a><b>afterExit</b>
      <p><b>Applies to:</b> Rule<br><b>Default:</b> unset, no extra exit prerequisite<br><b>Values:</b> location:DEVICE or group:GROUP</p>
      <p>Require an accepted, strictly earlier exit in the same resident's current trip. Group exit means leaving the last entered member. Reentry revokes the corresponding evidence. Completed return, rejected departure, geometry change, reset or clock discontinuity cannot transfer this history into another trip. Missing exits are not inferred.</p>
      <p>The prerequisite can be combined with arrivalFilter. It never replaces departure qualification, arrival confirmation, resident permissions or actuator checks. A Home exit does not remain a valid prerequisite after reentering Home.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.ReturnRoute afterExit group:Offices</pre>
    </li>
    <li><a id="GeoPresence-attr-arrivalFilter"></a><b>arrivalFilter</b>
      <p><b>Applies to:</b> Rule with trigger arrival<br><b>Values:</b> any, vehicle<br><b>Default:</b> any</p>
      <p>any adds no movement filter. vehicle requires recent automotive evidence or a confirmed remote trip without current contradictory walking, running or cycling. It does not identify a particular car. The result is retained through the deliberate Home confirmation wait.</p>
      <p>This filter works for any arrival action, including a light or notification. The garage_open adapter requires vehicle; door_open still requires personal door permission. Neither value permits an unqualified return.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.VehicleArrival arrivalFilter vehicle</pre>
    </li>
    <li><a id="GeoPresence-attr-action"></a><b>action</b>
      <p><b>Applies to:</b> Rule<br>
      <b>Requirement:</b> Required existing GeoPresence action device in the same controller; no default</p>
      <p>Select an existing action of this controller from the dropdown. References what the rule should execute, not the hardware target or a command string.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.PERSONGarden action Geo.Action.GardenLight</pre>
    </li>
    <li><a id="GeoPresence-attr-cooldown"></a><b>cooldown</b>
      <p><b>Applies to:</b> Rule<br>
      <b>Default:</b> <code>300</code> seconds<br>
      <b>Range:</b> integer 0&ndash;86400</p>
      <p>Minimum interval for notification/switch plans using the same action within a resident's state. This is not a global door/garage lockout.</p>
      <p>Duplicate events and repeated entries in the same visit remain suppressed even with 0; switch_on needs a new exit and entry for another visit.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.PERSONGarden cooldown 300</pre>
    </li>
  </ul>

  <a id="GeoPresence-readings"></a>
  <h4>Readings and logs</h4>
  <p>Production resident readings prefixed with gp_ show snapshots such as phase, location, trip and door/garage results. Locations store production geometry in gp_geometry. These readings are diagnostic and do not restore executable permissions. Debug uses get explain with debug, get debugTrace and the separate diagnostic file instead of updating readings.</p>
  <p>The normal FHEM log contains English production area transitions, phone presence changes, opening requests and feedback, switch requests and messages handed to pushMsg. A message handoff is not a delivery receipt and door pulse confirmation is not proof that the door is physically open. Configured aliases, labels and message text are kept verbatim. The standard verbose attribute controls this normal output; detailed structured diagnostics go exclusively to logFile according to debugLog, even at verbose 5.</p>
  <p>Timer statistics and diagnostic files are never used to restore permissions. Logging failures do not change webhook acceptance or decision state. The timer rechecks current configuration and schedules its next tick one second after completion; statistics distinguish callback work from delays caused elsewhere in FHEM.</p>
</div>

=end html

=cut
