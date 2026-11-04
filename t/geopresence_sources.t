use strict;
use warnings;
use Test::More;
use FindBin;
use POSIX qw(strftime tzset);
use Time::Local qw(timegm);
use MIME::Base64 qw(encode_base64);

our (%defs,%attr,%data,%keys,$init_done,$readingFnAttributes,$unicodeEncoding);
our ($now,$mono,@commands,@messages);
our $GP_SOURCE_NATIVE;
$readingFnAttributes=''; $unicodeEncoding=1;
sub setReadingsVal { $_[0]{READINGS}{$_[1]}={VAL=>$_[2],TIME=>$_[3]}; }
sub InternalTimer { }
sub RemoveInternalTimer { }
sub setNotifyDev { $_[0]{NOTIFYDEV}=$_[1]; }
sub deviceEvents { $_[0]{CHANGED}; }
sub Log3 { }
sub CommandSet { push @commands,$_[1]; return; }
sub pushMsg { push @messages,[@_]; }
sub readingsBeginUpdate {
    $_[0]{'.updateTime'}=$now;
    $_[0]{'.updateTimestamp'}=strftime('%Y-%m-%d %H:%M:%S',localtime($now));
    $_[0]{CHANGED}=[];
}
sub readingsBulkUpdate {
    my ($d,$reading,$value,undef,$timestamp)=@_;
    return if $d->{skip_update};
    setReadingsVal($d,$reading,$value,$timestamp||$d->{'.updateTimestamp'});
    push @{$d->{CHANGED}},"$reading: $value";
}
sub readingsEndUpdate {
    my ($d,$trigger)=@_;
    delete @{$d}{qw(.updateTime .updateTimestamp)};
    return unless $trigger;
    for my $c (values %defs) {
        next unless ($c->{TYPE}//'') eq 'GeoPresence' && ($c->{SUBTYPE}//'') eq 'controller';
        GeoPresence_Notify($c,$d) if grep {$_ eq $d->{NAME}} split /,/,$c->{NOTIFYDEV}//'';
    }
}
require "$FindBin::Bin/lib/FhemKeyStore.pm";
sub CommandAttr {
    my (undef,$text)=@_;
    my ($name,$key,$value)=split / /,$text,3;
    my $error=GeoPresence_Attr('set',$name,$key,$value);
    return $error if $error;
    $attr{$name}{$key}=$value;
    return;
}
require "$FindBin::Bin/../FHEM/98_GeoPresence.pm";
{
    no warnings qw(redefine once);
    *GP_Now=sub {$now}; *GP_Mono=sub {$mono};
    *GP_EnsureHTTP=sub {return;}; # Pure state tests; HTTP parsing still uses GP_HTTP.
}
my $password='test-password-123456789012345';
sub def {
    my ($name,$definition)=@_;
    my $d=$defs{$name}={NAME=>$name,TYPE=>'GeoPresence'};
    my $error=GeoPresence_Define($d,"$name GeoPresence $definition");
    die $error if defined $error;
    return $d;
}
sub advance { $now+=$_[0]; $mono+=$_[0]; }
sub config_event { GeoPresence_Notify($defs{GP},{NAME=>'global',CHANGED=>[@_]}); }
sub fixture {
    my ($profile)=@_;
    GP_SourceSubscriptions($_,{}) for grep {($_->{TYPE}//'') eq 'GeoPresence' && ($_->{SUBTYPE}//'') eq 'controller'} values %defs;
    %defs=(); %attr=(); %data=(); %keys=(); @commands=(); @messages=();
    $now=1790000000; $mono=1000; $init_done=0;
    $defs{rr_Test}={NAME=>'rr_Test',TYPE=>'ROOMMATE'};
    $attr{rr_Test}{rr_locationUnderway}='underway';
    my $c=def('GP','controller'); $attr{GP}={webhookPort=>8090}; GP_StoreMode($defs{GP},'debug');
    def('Geo.Test','resident GP rr_Test');
    $attr{'Geo.Test'}={sourceMode=>$profile//'geofency_only',allowDoor=>1,allowGarage=>1}; GP_StoreMode($defs{'Geo.Test'},'debug');
    if (($profile//'') ne 'phone_only') {
        $attr{'Geo.Test'}{deviceId}='phone'; $attr{'Geo.Test'}{webhookUser}='user';
        $keys{'GeoPresence_Geo.Test_auth'}='a'x32 . ':'.Digest::SHA::sha256_hex('a'x32 . ':'.$password);
    }
    if (($profile//'') =~ /^(?:phone_only|geofency_phone)$/) {
        $defs{p1}={NAME=>'p1',TYPE=>'PRESENCE'};
        $attr{'Geo.Test'}{phoneProxies}='p1';
    }
    for my $z ([Home=>'home',0,50],[Outer=>'outer',0,4500],[Helper=>'place',0.01,100],
               [Near=>'place',0.001,50],[Drive=>'approach',0,250],[Work=>'place',0.1,100]) {
        next if ($profile//'') eq 'phone_only';
        my ($n,$role,$lat,$radius)=@$z;
        def("Z.$n","location Geo.Test $role"); $attr{"Z.$n"}{zoneId}=lc($n);
        $defs{"Z.$n"}{READINGS}{gp_geometry}{VAL}=JSON::PP::encode_json({lat=>$lat,lon=>0,radius=>$radius,
            time=>$now-1000,changed=>$now-1000,device=>'phone',id=>lc($n),blocked=>0});
    }
    for my $kind (qw(door garage)) {
        $defs{$_}={NAME=>$_,TYPE=>'dummy'} for ($kind,"$kind.contact","$kind.state","$kind.upper","$kind.lower");
        def("A.$kind","action GP ${kind}_open");
        $attr{"A.$kind"}={target=>$kind,command=>$kind eq 'door'?'lock unlocked':'on',
            $kind eq 'door' ? (contact=>'door.contact',feedbackDevice=>'door.state')
                : (stateDevice=>'garage.state',upperContact=>'garage.upper',lowerContact=>'garage.lower')};
        def("R.$kind",'rule GP');
        $attr{"R.$kind"}={residents=>'Geo.Test',trigger=>'arrival',action=>"A.$kind",
            arrivalFilter=>$kind eq 'door'?'any':'vehicle'};
    }
    $init_done=1; GP_UpdateAttrLists(); GP_ResetController($c); $c->{helper}{gp}{ready}=1;
    my $cfg=GP_Config($c,'Geo.Test',1); my $s=GP_State($c,'Geo.Test',1);
    advance(40);
    return ($c,$cfg,$s);
}
sub event {
    my ($s,$cfg,$zone,$entry,$motion)=@_;
    GP_Process($s,$cfg,{kind=>'geo',zone=>'Z.'.$zone,entry=>$entry,motion=>$motion//'unknown',
        time=>$now,received=>$now,key=>join(':',$zone,$entry,$now)},$now,$mono);
}
sub finish { my ($s,$cfg)=@_; advance($s->{arrival}{wait}+1); GP_ConfirmArrival($s,$cfg,$now,$mono); }

sub in_timezone {
    my ($zone,$call)=@_;
    my $error;
    { local $ENV{TZ}=$zone; tzset(); eval {$call->();1} or $error=$@; }
    tzset();
    die $error if $error;
}

sub source_update {
    my ($name,$reading,$value,$epoch,$explicit)=@_;
    my $d=$defs{$name};
    readingsBeginUpdate($d);
    if (defined $epoch) {
        $d->{'.updateTime'}=$epoch;
        $d->{'.updateTimestamp'}=strftime('%Y-%m-%d %H:%M:%S',localtime($epoch));
    }
    readingsBulkUpdate($d,$reading,$value,undef,$explicit);
    readingsEndUpdate($d,1);
}

subtest 'source requirements and defaults' => sub {
    for my $mode (qw(geofency_phone geofency_only phone_only)) {
        my ($c,$cfg)=fixture($mode);
        is_deeply([GP_Validate($c)],[],"$mode validates with only its sources");
        if ($mode eq 'geofency_only') {
            is_deeply($cfg->{proxies},[],'no dummy phone source');
            is($cfg->{phoneSignalMode},'disabled','disabled is distinct from an unavailable sensor');
            local $attr{'Geo.Test'}{phoneProxies}='missing';
            is_deeply([GP_Validate($c)],[],'inactive sensors do not invalidate geo processing');
            like(GeoPresence_Get($c,'GP','validate'),qr/phoneProxies not used by geofency_only/,'unused stored settings explicitly reported');
        } elsif ($mode eq 'phone_only') {
            like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','mode','learning'),qr/Geofency source/,'learning unavailable');
        } else {
            delete $attr{'Geo.Test'}{sourceMode};
            is(GP_Config($c,'Geo.Test')->{sourceMode},'geofency_phone','combined remains the default');
        }
    }
    my ($c)=fixture(); delete $attr{'Geo.Test'}{deviceId};
    config_event('DELETEATTR Geo.Test deviceId');
    like(join(' ',GP_Validate($c)),qr/deviceId and webhookUser required/,'geo-only identity remains mandatory');
    $attr{'Geo.Test'}{sourceMode}='invalid';
    config_event('ATTR Geo.Test sourceMode invalid');
    like(join(' ',GP_Validate($c)),qr/invalid sourceMode/,'unknown profile fails closed');
};

subtest 'geo-only has neither actual nor simulated phone observations' => sub {
    my ($c,$cfg,$s)=fixture();
    for my $command (qw(debugPhoneMode debugPhone)) {
        like(GeoPresence_Set($c,'GP',$command,'Geo.Test','simulated'),qr/Phone source disabled/,'phone simulation rejected');
    }
    {
        no warnings qw(redefine once);
        local *GP_PhoneSamples=sub {die 'phone sampling must not run'};
        local *GP_Phone=sub {die 'phone processing must not run'};
        GP_TimerStep($c,$c->{helper}{gp},$now,$mono);
        like(GeoPresence_Get($c,'GP','explain','Geo.Test'),qr/no phone fallback/,'readable report explains missing fallback without sampling');
    }
    is($s->{phone}{state},'disabled','phone remains disabled after timer');
    ok(!exists($s->{phone_poll_at}),'no phone poll scheduled');
    for my $kind (qw(phone_present phone_absent phone_snapshot)) {
        GP_Process($s,$cfg,{kind=>$kind,time=>$now,received=>$now},$now,$mono);
        is($s->{phase},'unknown',"$kind cannot synchronize status");
    }
    my $report=JSON::PP::decode_json(GeoPresence_Get($c,'GP','explain','Geo.Test','format=json'));
    is_deeply($report->{sources},{geofency=>1,phone=>0},'JSON explicitly identifies active sources');
};

subtest 'Home exit, time and motion alone never authorize opening' => sub {
    for my $motion (qw(walking automotive)) {
        my ($c,$cfg,$s)=fixture();
        event($s,$cfg,'Home',0); advance(600); GP_TickState($s,$cfg,$now,$mono);
        is($s->{desired_status},'absent','Home exit still updates absence after grace');
        ok(!$s->{trip}{armed},'elapsed time has not qualified departure');
        like(GeoPresence_Get($c,'GP','explain','Geo.Test','debug'),qr/additional distance evidence required/,'missing evidence explained');
        advance(1); event($s,$cfg,'Home',1,$motion);
        is($s->{phase},'home',"$motion arrival synchronizes status");
        is_deeply($s->{intents},[],"$motion cannot substitute for distance evidence");
        ok(!$s->{arrival},'no delayed permission scheduled');
    }
};

subtest 'nearby helper and matching surrounding boundary do not prove distance' => sub {
    my ($c,$cfg,$s)=fixture();
    event($s,$cfg,'Home',0); advance(1); event($s,$cfg,'Near',1);
    ok(!$s->{trip}{armed},'near helper cannot confirm');
    advance(1); event($s,$cfg,'Drive',0);
    ok(!$s->{trip}{armed},'250 m approach boundary has only 200 m clearance; strict margin required');
    $cfg->{zones}{'Z.Outer'}{radius}=50;
    advance(1); event($s,$cfg,'Outer',0);
    ok(!$s->{trip}{armed},'renamed copy of Home is not an independent distance indication');
};

subtest 'distant Geo evidence authorizes only a qualified and confirmed return' => sub {
    for my $case ([Outer=>0,'automotive',2],[Work=>1,'automotive',2],[Helper=>1,'walking',1]) {
        my ($zone,$entry,$motion,$count)=@$case;
        my ($c,$cfg,$s)=fixture();
        # A missing Home exit can be replaced by actual distant evidence.
        event($s,$cfg,$zone,$entry);
        ok($s->{trip}{armed},"$zone proves departure");
        advance(61); event($s,$cfg,'Home',1,$motion);
        is($s->{arrival}{wait},$motion eq 'automotive'?10:60,'motion determines confirmation wait');
        is_deeply($s->{intents},[],'entry does not dispatch immediately');
        finish($s,$cfg);
        is(scalar @{$s->{intents}},$count,"$zone produces the expected opening plans");
        GP_Dispatch($c,'Geo.Test',$cfg,$s,1,$now,$mono);
        is_deeply(\@commands,[],'debug dispatch executes no commands');
        advance(1); event($s,$cfg,'Home',1,$motion);
        is_deeply($s->{intents},[],'another Home webhook cannot repeat arrival');
    }
};

subtest 'a short Home jump cancels the pending return without consuming the trip' => sub {
    my ($c,$cfg,$s)=fixture(); event($s,$cfg,'Outer',0); advance(61);
    event($s,$cfg,'Home',1,'walking'); advance(15); event($s,$cfg,'Home',0);
    ok(!$s->{arrival} && $s->{trip}{armed},'jump cancelled; departure retained');
    advance(61); GP_TickState($s,$cfg,$now,$mono); GP_ConfirmArrival($s,$cfg,$now,$mono);
    is_deeply($s->{intents},[],'expired old wait cannot open');
    event($s,$cfg,'Home',1,'walking'); finish($s,$cfg);
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'real foot return opens only door');
};

subtest 'source changes revoke trips and refresh the relevant attribute selection' => sub {
    my ($c,$cfg,$s)=fixture(); event($s,$cfg,'Outer',0);
    is(CommandAttr(undef,'Geo.Test sourceMode geofency_phone'),undef,'change source while debug');
    ok(!exists($c->{helper}{gp}{debug}{'Geo.Test'}),'old departure cannot cross profile boundary');
    like($defs{'Geo.Test'}{'.AttrList'},qr/phoneProxies/,'combined mode offers phone sources immediately');
    like(join(' ',GP_Validate($c)),qr/phoneProxies must/,'combined profile requires actual sources');
    is(CommandAttr(undef,'Geo.Test sourceMode geofency_only'),undef,'restore geo-only');
    unlike($defs{'Geo.Test'}{'.AttrList'},qr/\bphone(?:Proxies|SignalMode)\b/,'geo-only hides phone attributes');
    like(GeoPresence_Attr('set','Geo.Test','phoneProxies','p1'),qr/not used/,'inapplicable set refused');
    is(GeoPresence_Attr('del','Geo.Test','phoneProxies',undef),undef,'inactive stored values remain deletable');
    is(CommandAttr(undef,'Geo.Test sourceMode phone_only'),undef,'select phone-only');
    unlike($defs{'Geo.Test'}{'.AttrList'},qr/\b(?:deviceId|webhookUser)\b/,'phone-only hides Geo identity attributes');
    unlike($defs{'Geo.Test'}{'.AttrList'},qr/\b(?:allowDoor|allowGarage)\b/,'phone-only offers no opening controls');
    like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','webhookPassword',$password),qr/no Geofency source/,'password setup unavailable in phone-only');
};

subtest 'configuration order and return to the default profile' => sub {
    my ($c)=fixture();
    {
        local $init_done=0;
        GP_UpdateAttrLists();
        like($defs{'Geo.Test'}{'.AttrList'},qr/phoneProxies/,'loading accepts attributes before final profile is known');
        is(CommandAttr(undef,'Geo.Test phoneProxies p1'),undef,'stored phone list can load before or after sourceMode');
        is(CommandAttr(undef,'Geo.Test sourceMode phone_only'),undef,'profile accepted during load');
        is(CommandAttr(undef,'Geo.Test webhookUser user'),undef,'stored inactive Geo field can load in either order');
    }
    GP_UpdateAttrLists();
    unlike($defs{'Geo.Test'}{'.AttrList'},qr/webhookUser/,'finished loading hides inactive field');
    is(GeoPresence_Attr('del','Geo.Test','sourceMode',undef),undef,'remove explicit profile');
    delete $attr{'Geo.Test'}{sourceMode};
    like($defs{'Geo.Test'}{'.AttrList'},qr/webhookUser/,'deletion immediately restores combined widgets');
    like($defs{'Geo.Test'}{'.AttrList'},qr/phoneProxies/,'default profile also offers phone sources');
};

subtest 'geo-only learning uses the authenticated test webhook without sensors or identity' => sub {
    my ($c)=fixture(); delete $attr{'Geo.Test'}{deviceId};
    like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','mode','learning'),qr/Learning for/,'learning starts without sensors');
    my $body='device=new-phone&id=new-home&name=Home&entry=1&latitude=49&longitude=8&radius=50&isTest=true&date='.
        strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now));
    my $headers={'content-type'=>'application/x-www-form-urlencoded',authorization=>'Basic '.encode_base64('user:'.$password,'')};
    is((GP_HTTP($c,'POST','/fhem/geopresence',$headers,$body))[0],200,'authenticated test captures device and location');
    like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','learnConfirm'),qr/deviceId new-phone configured/,'explicit stop confirms identity');
    is($attr{'Geo.Test'}{deviceId},'new-phone','learned ID retained');
    is_deeply(\@commands,[],'learning has no productive commands');
    is_deeply(\@messages,[],'learning sends no messages');
};

subtest 'saved local timestamps retain their ambiguity and reject nonexistent clock times' => sub {
    in_timezone('Europe/Berlin',sub {
        fixture('phone_only');
        setReadingsVal($defs{p1},'presence','present','2026-10-25 02:30:00');
        my $v=GP_SourceReading('p1','presence');
        is($v->{earliest},timegm(0,30,0,25,9,2026),'first local occurrence is retained');
        is($v->{latest},timegm(0,30,1,25,9,2026),'second local occurrence is retained');
        is(GP_SourceReading('p1','presence')->{time},undef,'saved ambiguous time is not presented as an exact instant');
        is(GP_SourceReading('p1','presence'),$v,'unchanged reading reuses its interpretation');
        setReadingsVal($defs{p1},'presence','present','2026-03-29 02:30:00');
        ok(!defined(GP_SourceReading('p1','presence')->{earliest}),'spring gap supplies no valid source time');
        setReadingsVal($defs{p1},'presence','present','2026-10-25 03:30:00');
        is(GP_SourceReading('p1','presence')->{time},timegm(0,30,2,25,9,2026),'ordinary timestamp stays exact');
    });
    in_timezone('Australia/Lord_Howe',sub {
        fixture('phone_only');
        setReadingsVal($defs{p1},'presence','absent','2026-04-05 01:45:00');
        my $v=GP_SourceReading('p1','presence');
        is($v->{latest}-$v->{earliest},1800,'half-hour folds are handled without a fixed one-hour offset');
    });
};

subtest 'native phone updates remain ordered across the repeated local hour' => sub {
    in_timezone('Europe/Berlin',sub {
        for my $mode (qw(state measurement)) {
            my ($c)=fixture('phone_only');
            $attr{'Geo.Test'}{phoneSignalMode}=$mode; GP_InvalidateConfig($c);
            my $cfg=GP_Config($c,'Geo.Test',1);
            $now=timegm(0,55,0,25,9,2026); $mono=1000;
            my $s=GP_NewState($now-600,$mono-600,'source-clock','phone_only');
            source_update('p1','presence','present'); source_update('p1','state','present');
            my $sample=GP_PhoneSamples($cfg);
            is($sample->{p1}{time},$now,"$mode: first fold update keeps its actual epoch");
            my $event=GP_Phone($s,$cfg,$sample,$now,$mono); GP_Process($s,$cfg,$event,$now,$mono);
            my $first=$now;
            advance(600); source_update('p1','presence','present'); source_update('p1','state','present');
            $sample=GP_PhoneSamples($cfg);
            is($sample->{p1}{time},$now,"$mode: later update resolves the second fold correctly");
            cmp_ok($sample->{p1}{time},'>',$first,'backward local clock text does not reverse the source time');
            GP_Phone($s,$cfg,$sample,$now,$mono);
            is($s->{phone}{latest},$now,'current positive source is not discarded as older');
            my $record=GP_SourceReading('p1','presence');
            advance(10); GP_PhoneSamples($cfg);
            is(GP_SourceReading('p1','presence'),$record,'polling does not replace the actual update record');
        }
    });
};

subtest 'explicit old or ambiguous measurements do not acquire a fresh receipt time' => sub {
    in_timezone('Europe/Berlin',sub {
        my ($c)=fixture('phone_only');
        $attr{'Geo.Test'}{phoneSignalMode}='measurement'; GP_InvalidateConfig($c);
        my $cfg=GP_Config($c,'Geo.Test',1);
        $now=timegm(0,30,1,25,9,2026); $mono=5000;
        my $s=GP_NewState($now-600,$mono-600,'delayed-source','phone_only');
        source_update('p1','presence','present',undef,'2026-10-25 02:30:00');
        source_update('p1','state','present');
        my $sample=GP_PhoneSamples($cfg);
        ok($sample->{p1}{ambiguous},'explicit offset-free timestamp is not assigned the current fold');
        is(GP_Phone($s,$cfg,$sample,$now,$mono),undef,'ambiguous measurement creates no presence event');
        source_update('p1','presence','present',$now-3600);
        $sample=GP_PhoneSamples($cfg);
        is($sample->{p1}{time},$now-3600,'known older source epoch is retained exactly');
        is(GP_Phone($s,$cfg,$sample,$now,$mono),undef,'late measurement does not become fresh at receipt');
        advance(1); source_update('p1','presence','present');
        $sample=GP_PhoneSamples($cfg);
        is(GP_Phone($s,$cfg,$sample,$now,$mono)->{time},$now,'a genuinely new source update recovers normally');
    });
};

subtest 'delayed phone processing retains source receipt and the original monotonic budget' => sub {
    for my $explicit (0,1) {
        my ($c)=fixture('phone_only');
        $attr{'Geo.Test'}{phoneSignalMode}='measurement'; GP_InvalidateConfig($c);
        my $cfg=GP_Config($c,'Geo.Test',1);
        my $s=GP_NewState($now-600,$mono-600,'delayed-processing','phone_only');
        my ($observed,$received,$received_mono)=($now-5,$now,$mono);
        source_update('p1','presence','present',$explicit ? undef:$observed,
            $explicit ? strftime('%Y-%m-%d %H:%M:%S',localtime($observed)):undef);
        source_update('p1','state','present');
        advance(20); $now-=2;
        my $event=GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono);
        is($event->{time},$observed,'original measurement time survives delayed processing');
        is($event->{received},$received,'polling preserves the first actual receipt');
        is($event->{received_mono},$received_mono,'polling preserves the monotonic receipt');
        is(GP_ActionMonoExpiry($cfg,$event,$now,$mono),$received_mono+$cfg->{action_max_age}-5,
            'a backward wall correction does not refund action time');
        advance(126);
        GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono);
        isnt($s->{phone}{health},'fresh','measurement expiry uses elapsed source age despite the wall correction');
    }
};

subtest 'ambiguous held presence supplies status while fresh sources retain their own evidence' => sub {
    in_timezone('Europe/Berlin',sub {
        my ($c)=fixture('phone_only');
        $now=timegm(0,30,1,25,9,2026); $mono=5000;
        my $cfg=GP_Config($c,'Geo.Test',1);
        setReadingsVal($defs{p1},$_,'present','2026-10-25 02:30:00') for qw(state presence);
        my $s=GP_NewState($now-60,$mono-60,'held-source','phone_only');
        my $event=GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono);
        is($event->{kind},'phone_snapshot','ambiguous held state is status-only');
        GP_Process($s,$cfg,$event,$now,$mono);
        is($s->{phase},'home','held positive state still synchronizes presence');
        ok(!@{$s->{intents}},'held state supplies no arrival action');
        $defs{p2}={NAME=>'p2',TYPE=>'PRESENCE'};
        $attr{'Geo.Test'}{phoneProxies}='p1,p2'; GP_InvalidateConfig($c);
        $cfg=GP_Config($c,'Geo.Test',1);
        source_update('p2','presence','present'); source_update('p2','state','present');
        $s=GP_NewState($now-60,$mono-60,'mixed-sources','phone_only');
        $event=GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono);
        is($event->{kind},'phone_present','independent exact source retains its fresh presence');
        is($event->{time},$now,'uncertain source does not replace the exact source time');
    });
};

subtest 'late ambiguous presence revokes pending arrivals while preserving newer positions' => sub {
    in_timezone('Europe/Berlin',sub {
        my $base=timegm(0,0,2,25,9,2026);
        for my $case ([overlap=>8000,3000,0,1],[before_start=>4000,3000,0,1],
            [after_departure=>8000,5000,0,1],[mixed=>8000,3000,1,1],
            [reversed=>8000,3000,2,1],[fresh_time=>8000,3000,0,1,-4490],
            [overlapping_source=>6000,2100,0,1,0,3000],
            [overlapping_mixed=>6000,2100,1,1,0,3000],
            [overlapping_reversed=>6000,2100,2,1,0,3000],
            [equal_lower_time=>6000,2100,0,1,0,4500],
            [later_trip=>800,600,0,0]) {
            my ($name,$start_age,$departure_age,$mixed,$revoke,$offset,$negative_age)=@$case;
            my $poll=$base+($offset//0);
            my ($c)=fixture('geofency_phone');
            if ($mixed) {
                $defs{p2}={NAME=>'p2',TYPE=>'PRESENCE'};
                $attr{'Geo.Test'}{phoneProxies}=$mixed==2 ? 'p2,p1':'p1,p2';
                GP_InvalidateConfig($c);
            }
            my $cfg=GP_Config($c,'Geo.Test',1);
            $now=$poll-$start_age; $mono=1000;
            my $s=GP_NewState($now,$mono,'held-presence','geofency_phone');
            my $negative=$poll-($negative_age//6000);
            my $first=$negative>$now+40 ? $negative:$now+40;
            advance($first-$now);
            for my $proxy (@{$cfg->{proxies}}) {
                source_update($proxy,'presence','absent',$negative);
                source_update($proxy,'state','absent');
            }
            GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono);
            advance($poll-$departure_age-$now); event($s,$cfg,'Work',1);
            ok($s->{trip}{armed} && !$s->{trip}{phone_qualification},"$name: independent Geo trip is armed");
            advance($poll-10-$now); event($s,$cfg,'Home',1);
            my $pending=$s->{arrival}; my $position=$s->{position_time}; my $revision=$s->{output_revision};
            ok($pending,"$name: Home arrival is pending before the delayed presence");
            advance(10);
            source_update('p1','presence','present',undef,'2026-10-25 02:45:00');
            source_update('p1','state','present');
            if ($mixed) { source_update('p2','presence','present'); source_update('p2','state','present'); }
            my $e=GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono);
            is($e->{uncertain_until},$base-900,"$name: possible later time survives source selection");
            ok(GP_Fresh($cfg,$e,$now) && $e->{ambiguous},'a recent possible time remains explicitly ambiguous')
                if $name eq 'fresh_time';
            GP_Process($s,$cfg,$e,$now,$mono);
            is($s->{position_time},$mixed ? $poll:$position,"$name: status does not invent or rewind a position");
            if ($revoke) {
                ok(!$s->{trip} && !$s->{arrival},"$name: trip and waiting arrival are revoked");
                cmp_ok($s->{output_revision},'>',$revision,"$name: previously issued output plans lose permission");
            } else {
                is($s->{arrival},$pending,'presence entirely before a later session does not cancel its trip');
            }
            advance($pending->{due_mono}-$mono+1); GP_ConfirmArrival($s,$cfg,$now,$mono);
            is(scalar(grep {GP_IsOpening($_->{kind})} @{$s->{intents}}),$revoke ? 0:2,
                "$name: only the independently valid later trip can still plan opening");
            is_deeply(\@commands,[],"$name: source handling dispatches no commands");
        }
    });
};

subtest 'overlapping source ranges are consumed once without losing known ordering' => sub {
    in_timezone('Europe/Berlin',sub {
        my $poll=timegm(0,0,2,25,9,2026);
        my ($c,$cfg)=fixture('phone_only');
        $now=$poll-3000; $mono=4000;
        my $s=GP_NewState($poll-6000,$mono-3000,'source-order','phone_only');
        source_update('p1','presence','absent'); source_update('p1','state','absent');
        GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono);
        advance(3000);
        source_update('p1','presence','present',undef,'2026-10-25 02:45:00');
        source_update('p1','state','present');
        my $event=GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono);
        is($event->{uncertain_until},$poll-900,'possible later presence survives the prior negative source time');
        is($event->{time},$poll-4500,'acceptance preserves the original lower time');
        my $record=$s->{phone}{samples}{p1};
        advance(1);
        is(GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono),undef,'unchanged overlap emits no second event');
        is($s->{phone}{samples}{p1},$record,'unchanged polls reuse the compact source state');
        for my $old (['present','2026-10-25 02:00:00'],['absent','2026-10-25 02:00:00']) {
            source_update('p1','presence',$old->[0],undef,$old->[1]);
            source_update('p1','state',$old->[0]);
            is(GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono),undef,'a definitely earlier source creates no event');
            is($s->{phone}{samples}{p1},$record,'earlier ambiguity cannot roll back the known source boundary');
        }
        source_update('p1','presence','absent'); source_update('p1','state','absent');
        GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono);
        advance($cfg->{phone_absence_window}+1);
        is(GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono)->{kind},'phone_absent',
            'a genuine later negative still qualifies after the full window');
        $defs{p1}{STATE}='disconnected';
        GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono);
        $defs{p1}{STATE}='absent';
        source_update('p1','presence','present',undef,'2026-10-25 02:45:00');
        source_update('p1','state','present');
        is(GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono),undef,'a source fault still blocks an old ambiguous observation');
        advance(1); source_update('p1','presence','present');
        is(GP_Phone($s,$cfg,GP_PhoneSamples($cfg),$now,$mono)->{time},$now,'a genuinely later exact update recovers normally');
    });
};

subtest 'second-fold actuator feedback uses its original update and rejects delayed saved data' => sub {
    in_timezone('Europe/Berlin',sub {
        my ($c)=fixture();
        $now=timegm(0,5,1,25,9,2026); $mono=5000;
        setReadingsVal($defs{'door.contact'},'state','closed','2026-10-25 02:00:00');
        my $position={kind=>'door_open',params=>{contact=>'door.contact',feedbackDevice=>'door.state'}};
        is(GP_ActorView($position,$now-10,undef,$mono-10),'closed','held contacts can use an entirely past ambiguous timestamp');
        $position->{params}{positionSignalMode}='measurement';
        is(GP_ActorView($position,$now-10,undef,$mono-10),'unknown','measurement contacts require an exact post-start update');
        source_update('door.contact','state','closed');
        is(GP_ActorView($position,$now-10,undef,$mono-10),'closed','exact native contact update works in the second fold');
        source_update('door.state','pulse_state','idle');
        my $actor={intent=>{kind=>'door_open',params=>{feedbackDevice=>'door.state'}},
            start=>$now,mono=>$mono,feedback=>{'door.state'=>{pulse_state=>{before=>GP_ReadingFingerprint(GP_SourceReading('door.state','pulse_state'))}}}};
        advance(1); source_update('door.state','pulse_state','confirmed');
        is(GP_ActorResult($actor),'confirmed','new second-fold pulse completes the actual reservation');
        source_update('door.state','pulse_state','failed',undef,'2026-10-25 02:05:01');
        is(GP_ActorResult($actor),undef,'ambiguous explicit terminal value cannot confirm a reservation');
        source_update('door.state','pulse_state','failed',$now-3600);
        is(GP_ActorResult($actor),undef,'known delayed terminal value remains older than the reservation');
    });
};

subtest 'only referenced opening actions register position-source observation' => sub {
    my ($c)=fixture();
    $defs{$_}={NAME=>$_,TYPE=>'dummy'} for qw(Unused.Door Unused.Contact Unused.Feedback);
    def('A.Unused','action GP door_open');
    $attr{'A.Unused'}={target=>'Unused.Door',command=>'lock unlocked',contact=>'Unused.Contact',feedbackDevice=>'Unused.Feedback'};
    GP_Config($c,'Geo.Test',1);
    source_update('Unused.Contact','state','closed');
    ok(!exists($defs{'Unused.Contact'}{helper}{gp_source_times}),'unused action creates no observation work');
    $defs{rr_Phone}={NAME=>'rr_Phone',TYPE=>'ROOMMATE'};
    $defs{'Phone.Sensor'}={NAME=>'Phone.Sensor',TYPE=>'PRESENCE'};
    def('Geo.Phone','resident GP rr_Phone');
    $attr{'Geo.Phone'}={sourceMode=>'phone_only',phoneProxies=>'Phone.Sensor'};
    def('R.Before','rule GP');
    $attr{'R.Before'}={residents=>'Geo.Phone',trigger=>'arrival',action=>'A.Unused'};
    GP_Config($c,'Geo.Test',1);
    source_update('Unused.Contact','state','closed');
    ok(!exists($defs{'Unused.Contact'}{helper}{gp_source_times}),'an earlier phone-only rule does not register Geo opening sources');
    def('R.Unused','rule GP');
    $attr{'R.Unused'}={residents=>'Geo.Test',trigger=>'arrival',action=>'A.Unused'};
    GP_Config($c,'Geo.Test',1);
    source_update('Unused.Contact','state','closed');
    my $record=$defs{'Unused.Contact'}{helper}{gp_source_times}{state};
    is($record->{time},$now,'enabled applicable rule registers the actor input');
    def('R.ZDuplicate','rule GP');
    $attr{'R.ZDuplicate'}={residents=>'Geo.Test,Geo.Test',trigger=>'arrival',action=>'A.Unused'};
    GP_Config($c,'Geo.Test',1);
    like(join(' ',@{$c->{helper}{gp_config}{rule_errors}{'R.ZDuplicate'}}),qr/duplicate resident/,
        'an already selected opening action does not skip validation of later rules');
    $attr{'R.ZDuplicate'}{enabled}=0;
    $attr{'R.Unused'}{enabled}=0; GP_InvalidateConfig($c); GP_Config($c,'Geo.Test',1);
    advance(1); source_update('Unused.Contact','state','open');
    is($defs{'Unused.Contact'}{helper}{gp_source_times}{state},$record,'disabled unused action stops refreshing source metadata');
};

subtest 'source writes remain observed without unnecessary Notify subscriptions' => sub {
    my ($c)=fixture('geofency_phone');
    is_deeply([sort split /,/,$c->{NOTIFYDEV}],[qw(global rr_Test)],
        'idle Notify covers only global events and the ROOMMATE');
    my $notify=\&GeoPresence_Notify; my @notified;
    no warnings 'redefine';
    local *GeoPresence_Notify=sub {push @notified,$_[1]{NAME}; return $notify->(@_)};
    source_update('p1','presence','absent');
    source_update('door.contact','state','closed');
    source_update('door.state','pulse_state','idle');
    is_deeply(\@notified,[],'phone and idle actor sources cause no Notify processing');
    is(GP_SourceReading('p1','presence')->{time},$now,'phone write retains its exact epoch without Notify');
    is(GP_SourceReading('door.contact','state')->{time},$now,'position write retains its exact epoch without Notify');
    source_update('p1','pulse_state','idle');
    my $actor=$c->{helper}{gp}{actors}{door}={intent=>{kind=>'door_open',params=>{feedbackDevice=>'p1'}},
        start=>$now,mono=>$mono,timeout=>60,waiters=>{},
        feedback=>{p1=>{pulse_state=>{before=>GP_ReadingFingerprint(GP_SourceReading('p1','pulse_state'))}}}};
    GP_UpdateNotifyDevices($c);
    is_deeply([sort split /,/,$c->{NOTIFYDEV}],[qw(global p1 rr_Test)],
        'a phone device is subscribed when it also supplies pending actor feedback');
    advance(1); source_update('p1','pulse_state','confirmed'); source_update('p1','pulse_state','idle');
    is($actor->{completion},'confirmed','short-lived completion is retained through Notify');
    GP_ActorFeedback($c,$now,$mono);
    ok(!$c->{helper}{gp}{actors}{door},'confirmed reservation is released');
    is_deeply([sort split /,/,$c->{NOTIFYDEV}],[qw(global rr_Test)],'completion removes the temporary feedback subscription');
    my $finished=$defs{p1}{helper}{gp_source_times}{pulse_state};
    advance(1); source_update('p1','pulse_state','confirmed');
    is($defs{p1}{helper}{gp_source_times}{pulse_state},$finished,
        'completion also removes the temporary write source without changing the catalogue');
    @notified=(); advance(1); source_update('p1','presence','present');
    is_deeply(\@notified,[],'continued phone observation requires no new Notify subscription');
    is(GP_SourceReading('p1','presence')->{time},$now,'source metadata keeps updating after actor completion');
    source_update('rr_Test','state','home');
    is_deeply(\@notified,['rr_Test'],'ROOMMATE events remain subscribed');
};

subtest 'source observation preserves call context, prototypes and exception cleanup' => sub {
    my ($c)=fixture('phone_only');
    my $writer=\&setReadingsVal; my @contexts;
    readingsBeginUpdate($defs{p1});
    {
        local $GP_SOURCE_NATIVE=sub {
            push @contexts,defined(wantarray) ? wantarray ? 'list':'scalar':'void';
            setReadingsVal($_[0],$_[1],$_[2],$_[0]{'.updateTimestamp'});
            return wantarray ? ('first','second'):'scalar';
        };
        my @values=readingsBulkUpdate($defs{p1},'presence','present');
        my $value=readingsBulkUpdate($defs{p1},'presence','present');
        readingsBulkUpdate($defs{p1},'presence','present');
        is_deeply(\@values,['first','second'],'list result passes through');
        is($value,'scalar','scalar result passes through');
    }
    is_deeply(\@contexts,[qw(list scalar void)],'original writer receives the caller context');
    {
        local $GP_SOURCE_NATIVE=sub {die "source write failed\n"};
        eval {readingsBulkUpdate($defs{p1},'presence','present')};
        is($@,"source write failed\n",'original source exception passes through');
    }
    is(\&setReadingsVal,$writer,'scoped writer binding is restored after exceptions');
    is(prototype(\&readingsBulkUpdate),prototype($GP_SOURCE_NATIVE),'core prototype is preserved');
};

subtest 'source observers retain real write identity and release the core boundary' => sub {
    my ($c)=fixture('phone_only');
    source_update('p1','presence','present');
    my $first=GP_SourceReading('p1','presence');
    {
        advance(1); local $defs{p1}{skip_update}=1;
        source_update('p1','presence','absent');
        is(GP_SourceReading('p1','presence'),$first,'filtered non-write does not refresh source metadata');
    }
    $defs{unrelated}={NAME=>'unrelated',TYPE=>'dummy'};
    source_update('unrelated','state','on');
    ok(!exists($defs{unrelated}{helper}{gp_source_times}),'unwatched devices gain no source cache');
    my $native=$GP_SOURCE_NATIVE;
    my $replacement=$defs{GP}={NAME=>'GP',TYPE=>'GeoPresence',SUBTYPE=>'controller',CONTROLLER=>'GP',helper=>{}};
    GP_SourceSubscriptions($replacement,{"p1\0presence"=>['p1','presence']});
    GP_SourceSubscriptions($c,{});
    isnt(\&readingsBulkUpdate,$native,'a stale controller cannot release the current observation');
    GP_SourceSubscriptions($c,{"unrelated\0state"=>['unrelated','state']});
    advance(1); source_update('p1','presence','present'); source_update('unrelated','state','off');
    is(GP_SourceReading('p1','presence')->{time},$now,'a stale registration cannot replace the current source set');
    ok(!exists($defs{unrelated}{helper}{gp_source_times}),'stale registration cannot add another source');
    delete $defs{GP};
    GP_SourceSubscriptions($replacement,{});
    is(\&readingsBulkUpdate,$native,'the owner can release its binding after removal from defs');
};

subtest 'source observation follows the current device identity' => sub {
    my ($c)=fixture('phone_only');
    source_update('p1','presence','present');
    my $old=$defs{p1}; my $record=$old->{helper}{gp_source_times}{presence};
    $defs{p1}={NAME=>'p1',TYPE=>'PRESENCE'};
    advance(1); source_update('p1','presence','absent');
    ok(!exists($defs{p1}{helper}{gp_source_times}),'same name does not authorize an unregistered replacement device');
    GP_SourceSubscriptions($c,{"p1\0presence"=>['p1','presence']});
    source_update('p1','presence','present');
    is(GP_SourceReading('p1','presence')->{time},$now,'registration resolves the replacement device');
    readingsBeginUpdate($old); readingsBulkUpdate($old,'presence','absent'); readingsEndUpdate($old,1);
    is($old->{helper}{gp_source_times}{presence},$record,'retained old devices cannot update source evidence');
};

subtest 'source release preserves a foreign reading wrapper' => sub {
    my ($c)=fixture('phone_only');
    source_update('p1','presence','present');
    my $record=$defs{p1}{helper}{gp_source_times}{presence};
    my $native=$GP_SOURCE_NATIVE; my $observe=\&readingsBulkUpdate; my $calls=0;
    my $foreign=sub {$calls++; return $observe->(@_)};
    {
        no warnings 'redefine';
        local *readingsBulkUpdate=$foreign;
        GP_SourceSubscriptions($c,{});
        advance(1); source_update('p1','presence','absent');
        is($defs{p1}{helper}{gp_source_times}{presence},$record,'released observation only forwards the foreign call');
        GP_SourceSubscriptions($c,{"p1\0presence"=>['p1','presence']});
        advance(1); source_update('p1','presence','present');
        is(GP_SourceReading('p1','presence')->{time},$now,'new observation works through the existing foreign wrapper');
        is(\&readingsBulkUpdate,$foreign,'registration does not replace the foreign binding');
        is($calls,2,'the foreign wrapper receives both updates');
        GP_SourceSubscriptions($c,{});
    }
    GP_SourceSubscriptions($c,{});
    is(\&readingsBulkUpdate,$native,'the original core binding is restored when the foreign scope ends');
};

done_testing;
