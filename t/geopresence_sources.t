use strict;
use warnings;
use Test::More;
use FindBin;
use POSIX qw(strftime);
use MIME::Base64 qw(encode_base64);

our (%defs,%attr,%data,%keys,$init_done,$readingFnAttributes,$unicodeEncoding);
our ($now,$mono,@commands,@messages);
$readingFnAttributes=''; $unicodeEncoding=1;
sub setReadingsVal { $_[0]{READINGS}{$_[1]}={VAL=>$_[2],TIME=>$_[3]}; }
sub InternalTimer { }
sub RemoveInternalTimer { }
sub setNotifyDev { }
sub Log3 { }
sub CommandSet { push @commands,$_[1]; return; }
sub pushMsg { push @messages,[@_]; }
sub readingsBeginUpdate { }
sub readingsBulkUpdate { $_[0]{READINGS}{$_[1]}={VAL=>$_[2],TIME=>strftime('%Y-%m-%d %H:%M:%S',localtime($now))}; }
sub readingsEndUpdate { }
sub getKeyValue { return (undef,$keys{$_[0]}); }
sub setKeyValue { $keys{$_[0]}=$_[1]; return; }
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
sub fixture {
    my ($profile)=@_;
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
    like(join(' ',GP_Validate($c)),qr/deviceId and webhookUser required/,'geo-only identity remains mandatory');
    $attr{'Geo.Test'}{sourceMode}='invalid';
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

done_testing;
