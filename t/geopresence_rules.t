use strict;
use warnings;
use Test::More;
use FindBin;
use POSIX qw(strftime);
use MIME::Base64 qw(encode_base64);

our (%defs,%attr,%data,%keys,$init_done,$readingFnAttributes,$unicodeEncoding);
our ($now,$mono,@commands,@messages);
$readingFnAttributes=''; $unicodeEncoding=1;
sub InternalTimer { }
sub RemoveInternalTimer { }
sub setNotifyDev { }
sub Log3 { }
sub deviceEvents { return $_[0]{CHANGED}; }
sub CommandSet { push @commands,$_[1]; return; }
sub pushMsg { push @messages,[@_]; }
sub readingsBeginUpdate { }
sub readingsBulkUpdate { $_[0]{READINGS}{$_[1]}={VAL=>$_[2],TIME=>strftime('%Y-%m-%d %H:%M:%S',localtime($now))}; }
sub readingsEndUpdate { }
sub setReadingsVal { $_[0]{READINGS}{$_[1]}={VAL=>$_[2],TIME=>$_[3]}; }
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

sub rules_fixture {
    my ($c)=fixture();
    $attr{'Z.Work'}{groups}='Employment,Sport';
    $attr{'Z.Home'}{groups}='House';
    def('Z.Work2','location Geo.Test place'); $attr{'Z.Work2'}={zoneId=>'work2',groups=>'Employment'};
    $defs{'Z.Work2'}{READINGS}{gp_geometry}{VAL}=JSON::PP::encode_json({lat=>0.1005,lon=>0,radius=>100,
        time=>$now-1000,changed=>$now-1000,device=>'phone',id=>'work2',blocked=>0});
    $defs{lamp}={NAME=>'lamp',TYPE=>'dummy'};
    def('A.Message','action GP notify'); $attr{'A.Message'}={message=>'%resident% event',channel=>0,priority=>0};
    def('A.Light','action GP switch_on'); $attr{'A.Light'}={target=>'lamp',command=>'on'};
    for my $row ([GroupEnter=>'enter','Employment',''],[GroupExit=>'exit','Employment',''],[Route=>'exit','','group:Employment']) {
        my ($name,$trigger,$group,$after)=@$row;
        def('R.'.$name,'rule GP'); $attr{'R.'.$name}={residents=>'Geo.Test',trigger=>$trigger,action=>'A.Message',cooldown=>0};
        if ($group) { $attr{'R.'.$name}{locationGroup}=$group; }
        else { $attr{'R.'.$name}{locations}='Z.Helper'; }
        $attr{'R.'.$name}{afterExit}=$after if $after;
    }
    GP_UpdateAttrLists(); $c->{helper}{gp}{ready}=1;
    my $cfg=GP_Config($c,'Geo.Test',1);my $s=GP_State($c,'Geo.Test',1);advance(40);
    return ($c,$cfg,$s);
}
sub plans { return [map {$_->{rule}} @{$_[0]{intents}}]; }

subtest 'FHEMWEB discovers separate set commands without changing runtime' => sub {
    my ($c,$cfg,$s)=fixture('geofency_phone');
    event($s,$cfg,'Outer',0);
    $c->{helper}{gp}{queue}=[{debug=>1,resident=>'Geo.Test',kind=>'geo'}];
    $c->{helper}{gp}{learning}{'Geo.Test'}=1;
    my $json=JSON::PP->new->canonical;
    my $before=$json->encode($c->{helper}{gp});
    my $answer=GeoPresence_Set($c,'GP','?');
    like($answer,qr/^Unknown argument.*choose one of /,'standard FHEM discovery response');
    $answer =~ s/^.*choose one of //;
    my %choices=map {split /:/,$_,2} split / /,$answer;
    is_deeply([sort keys %choices],[sort qw(mode applyGeometry debugReset debugPhoneMode debugPhone debugAdvance)],
        'one token per command, without syntax fragments');
    is($choices{applyGeometry},'select,,Geo.Test','geometry command offers resident selection');
    is($choices{debugReset},'select,,Geo.Test,Geo.Test#keepGeometry','reset choices retain optional argument');
    is($choices{debugPhoneMode},'select,,Geo.Test#live,Geo.Test#simulated','fixed phone modes offered as arguments');
    is($choices{debugPhone},'select,,Geo.Test#present,Geo.Test#absent','fixed phone values offered as arguments');
    is($choices{debugAdvance},'textField','variable number of seconds remains a text argument');
    for my $command (qw(applyGeometry debugReset debugPhoneMode debugPhone debugAdvance)) {
        like(GeoPresence_Set($c,'GP',$command),qr/^Usage: set GP \Q$command\E resident/,
            "$command explains missing arguments without masquerading as the command list");
    }
    like(GeoPresence_Set($c,'GP','unknown'),qr/^Unknown argument.*choose one of /,'unknown command returns valid choices');
    is($json->encode($c->{helper}{gp}),$before,'discovery and missing arguments preserve trips, queue, learning and geometry');
    is_deeply(\@commands,[],'no productive commands');
    is_deeply(\@messages,[],'no notifications');
};

subtest 'set choices follow resident source profiles and current definitions' => sub {
    my ($c)=fixture('geofency_only');
    $defs{'Geo.Phone'}={NAME=>'Geo.Phone',TYPE=>'GeoPresence',SUBTYPE=>'resident',CONTROLLER=>'GP'};
    $attr{'Geo.Phone'}={sourceMode=>'phone_only'};
    $defs{'Geo.Other'}={NAME=>'Geo.Other',TYPE=>'GeoPresence',SUBTYPE=>'resident',CONTROLLER=>'Other'};
    my $choices=GeoPresence_Set($c,'GP','?');
    like($choices,qr/applyGeometry:select,,Geo.Test(?: |$)/,'learning lists only Geofency residents');
    like($choices,qr/debugPhone:select,,Geo.Phone#present,Geo.Phone#absent(?: |$)/,'phone controls list only phone residents');
    unlike($choices,qr/Geo.Other/,'other controller residents excluded');
    like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','?'),qr/mode:active,debug,disabled,learning webhookPassword:textField learnConfirm:noArg$/,'geo resident exposes password command');
    like(GeoPresence_Set($defs{'Geo.Phone'},'Geo.Phone','?'),qr/choose one of mode:active,debug,disabled$/,'phone-only resident exposes no password command');
    like(GeoPresence_Set($defs{'Z.Home'},'Z.Home','?'),qr/choose one of $/,'locations expose no set commands');
    delete $defs{'Geo.Test'};
    like(GeoPresence_Set($c,'GP','?'),qr/applyGeometry:textField(?: |$)/,'empty resident selection is still a valid command widget');
    unlike(GeoPresence_Set($c,'GP','?'),qr/Geo.Test/,'deleted resident immediately disappears');
};

subtest 'generic schema, selectors and safe in-place location changes' => sub {
    my ($c,$cfg)=rules_fixture();
    is_deeply([GP_Validate($c)],[],'generic rules validate');
    my $h={};GeoPresence_Initialize($h);
    unlike($h->{AttrList},qr/(?:^| )(?:condition|role)(?: |:|$)/,'retired attributes are not registered');
    like($h->{AttrList},qr/trigger:arrival,enter,exit/,'generic event choices');
    unlike($defs{'R.door'}{'.AttrList'},qr/(?:^| )(?:locations|locationGroup)(?: |:|$)/,'arrival hides location selectors');
    unlike($defs{'R.GroupEnter'}{'.AttrList'},qr/(?:^| )(?:locations|arrivalFilter)(?: |:|$)/,'group selection hides irrelevant fields');
    like($defs{'R.Route'}{'.AttrList'},qr/afterExit:.*group:Employment/,'prior exit offers actual groups');
    for my $residents ('Unknown','Geo.Test,Geo.Test',',,') {
        local $attr{'R.Route'}{residents}=$residents;
        like(join(' ',GP_Validate($c)),qr/(?:unknown resident|duplicate resident|residents required)/,
            'invalid selection is caught even when no configured resident matches');
    }
    my $before=$defs{'Z.Work'}{READINGS}{gp_geometry}{VAL};
    is(GeoPresence_Define($defs{'Z.Work'},'Z.Work GeoPresence location Geo.Test place'),undef,'modify preserves existing location');
    is($defs{'Z.Work'}{READINGS}{gp_geometry}{VAL},$before,'geometry preserved');
    is($attr{'Z.Work'}{zoneId},'work','zone identity preserved');
    like(GeoPresence_Define($defs{'Z.Work'},'Z.Work GeoPresence location Geo.Test work'),qr/Invalid location function/,'old location function rejected');
    local $defs{GP}{READINGS}{mode}{VAL}='active';
    local $defs{'Geo.Test'}{READINGS}{mode}{VAL}='active';
    like(GeoPresence_Define($defs{'Z.Work'},'Z.Work GeoPresence location Geo.Test home'),qr/affects active residents/,'modify cannot bypass configuration mode');
};

subtest 'overlapping group membership and first/last transitions' => sub {
    my ($c,$cfg,$s)=rules_fixture();
    event($s,$cfg,'Work',1);is_deeply(plans($s),['R.GroupEnter'],'first entry');
    advance(1);event($s,$cfg,'Work2',1);is_deeply(plans($s),[],'overlap has no second group entry');
    advance(1);event($s,$cfg,'Work',0);is_deeply(plans($s),[],'leaving one member is not group exit');
    ok(!exists($s->{trip}{exits}{'group:Employment'}),'no incomplete exit proof');
    advance(1);event($s,$cfg,'Work2',0);is_deeply(plans($s),['R.GroupExit'],'last explicit exit');
    advance(1);event($s,$cfg,'Helper',0);is_deeply(plans($s),['R.Route'],'route after group exit');
    advance(1);event($s,$cfg,'Helper',0);is_deeply(plans($s),[],'same route does not repeat in trip');
};

subtest 'same-time, missing and revoked history cannot satisfy afterExit' => sub {
    my ($c,$cfg,$s)=rules_fixture();
    event($s,$cfg,'Helper',0);is_deeply(plans($s),[],'no prior history');
    advance(1);event($s,$cfg,'Work',0);
    event($s,$cfg,'Helper',0);is_deeply(plans($s),[],'same observation time is not prior');
    advance(1);event($s,$cfg,'Work',1);
    ok(!exists($s->{trip}{exits}{'group:Employment'}),'reentry revokes exit proof');
    advance(1);event($s,$cfg,'Helper',0);is_deeply(plans($s),[],'geometry may infer position but never the missing exit');
    advance(50000);GP_TickState($s,$cfg,$now,$mono);
    advance(1);event($s,$cfg,'Work2',0);
    ok(!exists($s->{trip}{exits}{'group:Employment'}),'expired display and another member exit do not invent missing group exit');
};

subtest 'individual exit is bounded to this resident and trip' => sub {
    my ($c,$cfg,$s)=rules_fixture();
    $attr{'R.Route'}{afterExit}='location:Z.Work'; $cfg=GP_Config($c,'Geo.Test',1);
    event($s,$cfg,'Work',0);advance(61);event($s,$cfg,'Helper',0);
    is_deeply(plans($s),['R.Route'],'individual exit matches');
    advance(1);event($s,$cfg,'Home',1,'walking');finish($s,$cfg);
    advance(1);event($s,$cfg,'Helper',0);is_deeply(plans($s),[],'completed trip cannot be reused');
    $attr{'R.Route'}{afterExit}='location:missing';
    like(join(' ',GP_Validate($c)),qr/invalid afterExit/,'unknown location reference invalid');
    $attr{'R.Route'}{afterExit}='group:Missing';
    like(join(' ',GP_Validate($c)),qr/invalid afterExit/,'unknown group reference invalid');
};

subtest 'local contradiction cannot create a generic exit prerequisite' => sub {
    my ($c,$cfg,$s)=rules_fixture();
    $cfg->{sourceMode}='geofency_phone';$cfg->{phoneSignalMode}='state';
    $s->{phone}={state=>'present',health=>'held',latest=>$now};
    event($s,$cfg,'Work',0);
    ok(!$s->{trip},'contradicted trip removed before recording history');
    $s->{phone}={state=>'unknown',health=>'unknown'};
    advance(100);event($s,$cfg,'Helper',0);is_deeply(plans($s),[],'next trip cannot borrow rejected group exit');
};

subtest 'vehicle filter is shared by light and notification, with confirmed arrival only' => sub {
    for my $kind (qw(switch_on notify)) {
        for my $motion (qw(walking automotive)) {
            my ($c,$cfg,$s)=rules_fixture();
            $cfg->{rules}=[{name=>'Vehicle',trigger=>'arrival',arrivalFilter=>'vehicle',afterExit=>'group:Employment',
                locations=>[],group=>'',cooldown=>0,type=>$kind,action=>'Generic',params=>{target=>'lamp',command=>'on',message=>'arrival'}}];
            event($s,$cfg,'Work',0);advance(61);event($s,$cfg,'Home',1,$motion);
            is_deeply(plans($s),[],'no output before confirmation');finish($s,$cfg);
            is_deeply(plans($s),$motion eq 'walking'?[]:['Vehicle'],"$kind uses generic vehicle filter for $motion");
            GP_Dispatch($c,'Geo.Test',$cfg,$s,1,$now,$mono);
            is_deeply(\@commands,[],'debug never sends light command');is_deeply(\@messages,[],'debug never sends notification');
        }
    }
};

subtest 'later reentry in the same batch cancels a pending route action' => sub {
    my ($c,$cfg,$s)=rules_fixture();event($s,$cfg,'Work',0);advance(1);event($s,$cfg,'Helper',0);
    my @pending=@{$s->{intents}};is(scalar @pending,1,'route planned');
    advance(1);event($s,$cfg,'Work',1);$s->{intents}=\@pending;
    GP_Dispatch($c,'Geo.Test',$cfg,$s,1,$now,$mono);
    ok(grep({$_->{reason} eq 'prior exit revoked before dispatch'} @{$s->{trace}}),'reentry revokes pending dispatch');
    ok(!grep({$_->{reason} eq 'would execute; debug suppressed' && $_->{rule} eq 'R.Route'} @{$s->{trace}}),'revoked plan is not even emitted in debug');
};

subtest 'Home repetitions preserve group membership, new trips do not reuse distant membership' => sub {
    my ($c,$cfg,$s)=rules_fixture();
    $cfg->{rules}=[{name=>'House',trigger=>'enter',group=>'House',locations=>[],cooldown=>0,action=>'HouseMessage',type=>'notify',params=>{message=>'home'}}];
    event($s,$cfg,'Home',1);is_deeply(plans($s),['House'],'first Home entry');
    advance(1);event($s,$cfg,'Home',1);is_deeply(plans($s),[],'duplicate Home remains same group visit');
    advance(1);event($s,$cfg,'Work',1);advance(61);event($s,$cfg,'Home',1);finish($s,$cfg);
    ok(!exists($s->{members}{'Z.Work'}),'confirmed home clears distant membership without generating an exit');
};

subtest 'shared groups never share residents, and prior exit references are validated per resident' => sub {
    my ($c,$cfg,$first)=rules_fixture();
    $defs{rr_Second}={NAME=>'rr_Second',TYPE=>'ROOMMATE'};
    def('Geo.Second','resident GP rr_Second');
    $attr{rr_Second}{rr_locationUnderway}='underway';
    $attr{'Geo.Second'}={sourceMode=>'geofency_only',deviceId=>'second-phone',webhookUser=>'second-user'}; GP_StoreMode($defs{'Geo.Second'},'debug');
    $keys{'GeoPresence_Geo.Second_auth'}=$keys{'GeoPresence_Geo.Test_auth'};
    for my $name (qw(Home Outer Work Work2 Helper)) {
        def("S.$name",'location Geo.Second '.$defs{"Z.$name"}{ROLE});
        $attr{"S.$name"}={%{$attr{"Z.$name"}}};
        my $geometry=JSON::PP::decode_json($defs{"Z.$name"}{READINGS}{gp_geometry}{VAL});
        $geometry->{device}='second-phone';
        $defs{"S.$name"}{READINGS}{gp_geometry}{VAL}=JSON::PP::encode_json($geometry);
    }
    $attr{$_}{residents}='Geo.Test,Geo.Second' for qw(R.GroupEnter R.GroupExit R.Route);
    $attr{'R.Route'}{locations}='Z.Helper,S.Helper';
    is_deeply([GP_Validate($c)],[],'same free group valid for both independent residents');
    my $second_cfg=GP_Config($c,'Geo.Second',1);
    my $second=GP_NewState($now-40,$mono-40,'second','geofency_only');
    event($first,$cfg,'Work',0);advance(1);
    GP_Process($second,$second_cfg,{kind=>'geo',zone=>'S.Helper',entry=>0,motion=>'unknown',time=>$now,received=>$now},$now,$mono);
    is_deeply(plans($second),[],'first resident exit cannot authorize second resident route');
    advance(1);
    GP_Process($second,$second_cfg,{kind=>'geo',zone=>'S.Work',entry=>0,motion=>'unknown',time=>$now,received=>$now},$now,$mono);
    advance(1);
    GP_Process($second,$second_cfg,{kind=>'geo',zone=>'S.Helper',entry=>0,motion=>'unknown',time=>$now,received=>$now},$now,$mono);
    is_deeply(plans($second),['R.Route'],'second resident own exit authorizes their route');
    $attr{'R.Route'}{afterExit}='location:Z.Work';
    like(join(' ',GP_Validate($c)),qr/invalid afterExit for Geo.Second/,'a concrete foreign resident reference is rejected');
};

subtest 'reentry after arrival confirmation still revokes a queued prerequisite' => sub {
    my ($c,$cfg,$s)=rules_fixture();
    $cfg->{rules}=[{name=>'Arrive',trigger=>'arrival',afterExit=>'location:Z.Near',arrivalFilter=>'any',
        locations=>[],group=>'',cooldown=>0,type=>'switch_on',action=>'A.Light',params=>{target=>'lamp',command=>'on'}}];
    event($s,$cfg,'Outer',0);advance(61);event($s,$cfg,'Near',0);
    advance(1);event($s,$cfg,'Home',1,'walking');finish($s,$cfg);
    my @pending=@{$s->{intents}};is_deeply(plans($s),['Arrive'],'qualified arrival retains the action for dispatch');
    ok(!$s->{trip} && $s->{last_trip},'trip has completed');
    advance(1);event($s,$cfg,'Near',1);$s->{intents}=\@pending;
    GP_Dispatch($c,'Geo.Test',$cfg,$s,1,$now,$mono);
    ok(grep({$_->{reason} eq 'prior exit revoked before dispatch'} @{$s->{trace}}),'reentry revokes even the just-completed trip proof');
    ok(!grep({$_->{reason} eq 'would execute; debug suppressed'} @{$s->{trace}}),'no late action emitted');
};

subtest 'manual home during dispatch cannot retain a completed trip prerequisite' => sub {
    my ($c,$cfg,$s)=rules_fixture();
    $defs{GP}{READINGS}{mode}{VAL}='active';$defs{'Geo.Test'}{READINGS}{mode}{VAL}='active';
    $c->{helper}{gp}{prod}{'Geo.Test'}=$s;$c->{helper}{gp}{ready}=1;
    $s->{phase}='home';
    $s->{last_trip}={id=>'old',exits=>{'group:Employment'=>$now-1}};
    my $intent={kind=>'notify',generation=>$s->{generation},rule=>'Pending',trip=>'old',after_exit=>'group:Employment',
        exit_time=>$now-1,params=>{message=>'return'},e=>{time=>$now,received=>$now}};
    $defs{rr_Test}{CHANGED}=['home'];
    GeoPresence_Notify($c,$defs{rr_Test});
    $s->{intents}=[$intent];GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is_deeply(\@messages,[],'manual arrival prevents pending prerequisite notification');
    ok(grep({$_->{reason} eq 'prior exit revoked before dispatch'} @{$s->{trace}}),'manual return invalidates completed-trip proof');
};

subtest 'missing place geometry is reported without blocking a configured Home' => sub {
    my ($c)=fixture('geofency_phone');
    delete $defs{$_}{READINGS}{gp_geometry} for qw(Z.Work Z.Helper);
    delete $c->{helper}{gp}{geometry};
    my $cfg=GP_Config($c,'Geo.Test',1);
    ok($cfg->{geometry_ready},'Home and outer geometry still satisfy the opening geometry contract');
    my ($validation)=GP_GetData($c,'GP','validate','Geo.Test');
    ok($validation->{valid},'location definitions remain valid');
    like(join(' ',@{$validation->{warnings}}),qr/registered places: Z.Helper, Z.Work/,'validation lists both missing places');
    my $state=GeoPresence_Get($c,'GP','explain','Geo.Test','debug');
    like($state,qr/Opening geometry is ready, but other registered locations still lack geometry: Z.Helper, Z.Work/,'opening readiness is distinct from completeness');
    like($state,qr/Missing location geometry\s+: Z.Helper, Z.Work/,'debug report names incomplete preparation');
    like(GeoPresence_Get($c,'GP','explain','Geo.Test','debug'),qr/automatic test application also needs these locations/s,'explains the different prerequisites');
    my $explain=GeoPresence_Get($c,'GP','explain','Geo.Test');
    like($explain,qr/locations still lack geometry: Z.Helper, Z.Work/,'default production view also names its missing geometry');
    for my $z (qw(Helper Work)) {
        my $s=GP_State($c,'Geo.Test',1);
        is(GP_UpdateGeometry($c,'Geo.Test',1,$s,{kind=>'geo',zone=>"Z.$z",time=>$now,received=>$now,
            geometry=>{lat=>0.1,lon=>0,radius=>100}},$cfg,$now),'changed','a new test webhook supplies missing geometry');
        advance(8);
    }
    my ($ready)=GP_GetData($c,'GP','validate','Geo.Test');
    is_deeply($ready->{warnings},[],'notice clears once debug geometry is available');
    like(GeoPresence_Get($c,'GP','explain','Geo.Test','debug'),qr/Geometry is available for all registered locations/,'all registered locations now available to tests');
    ok(!exists($defs{'Z.Work'}{READINGS}{gp_geometry}),'diagnosis and debug synchronization do not publish productive geometry');
    is_deeply(\@commands,[],'no actuator commands');
    is_deeply(\@messages,[],'no notifications');
};

subtest 'journey reset can retain geometry without retaining an arrival or touching production' => sub {
    my ($c,$cfg,$s)=fixture('geofency_phone');
    delete $defs{'Z.Work'}{READINGS}{gp_geometry};
    delete $c->{helper}{gp}{geometry}{debug}{'Geo.Test'}{'Z.Work'};
    is(GP_UpdateGeometry($c,'Geo.Test',1,$s,{kind=>'geo',zone=>'Z.Work',time=>$now,received=>$now,
        geometry=>{lat=>0.1,lon=>0,radius=>150}},$cfg,$now),'changed','unsaved geometry received in simulation');
    $cfg=GP_Config($c,'Geo.Test',1);
    event($s,$cfg,'Outer',0);advance(61);event($s,$cfg,'Home',1,'walking');
    ok($s->{trip}{armed} && $s->{arrival},'qualified trip has a pending arrival before cleanup');
    my $rt=$c->{helper}{gp};
    my $encode=sub {JSON::PP::encode_json($_[0])};
    my $geometry=JSON::PP::decode_json($encode->($rt->{geometry}{debug}{'Geo.Test'}));
    my $production=GP_State($c,'Geo.Test',0);
    my $production_before=$encode->($production);
    $rt->{debug}{'Geo.Other'}={trip=>{armed=>1}};
    $rt->{queue}=[{debug=>1,resident=>'Geo.Test',kind=>'geo'},
        {debug=>1,resident=>'Geo.Other',kind=>'geo'},{debug=>0,resident=>'Geo.Test',kind=>'geo'}];
    $rt->{learning}{'Geo.Test'}=1;
    $rt->{learned}{'Geo.Test'}={unbound=>1,zones=>{}};
    my $result=GeoPresence_Set($c,'GP','debugReset','Geo.Test','keepGeometry');
    is($result,'Debug session reset; geometry retained; no productive changes','geometry retention acknowledged');
    is_deeply($rt->{geometry}{debug}{'Geo.Test'},$geometry,'coordinates, timestamps and identities retained unchanged');
    $s=GP_State($c,'Geo.Test',1);
    ok(!$s->{trip} && !$s->{arrival} && !$s->{last_trip},'departure and arrival permissions discarded');
    is_deeply($s->{intents},[],'no pending debug actions');
    is_deeply($s->{zones},{},'geometry does not restore observed visits');
    is_deeply($s->{seen},{},'event deduplication reset');
    is_deeply($s->{notify_seen},{},'notification history reset');
    is($s->{phone_mode}//'live','live','phone simulation reset');
    ok(!exists($rt->{learning}{'Geo.Test'}) && !exists($rt->{learned}{'Geo.Test'}),'learning reception and unconfirmed candidate discarded');
    is_deeply($rt->{queue},[{debug=>1,resident=>'Geo.Other',kind=>'geo'},
        {debug=>0,resident=>'Geo.Test',kind=>'geo'}],'only own debug queue cleared');
    is($encode->($production),$production_before,'productive state unchanged');
    ok($rt->{debug}{'Geo.Other'}{trip}{armed},'another resident unaffected');
    ok(!exists($defs{'Z.Work'}{READINGS}{gp_geometry}),'no productive reading created');
    event($s,$cfg,'Home',1,'walking');
    ok(!$s->{trip} && !$s->{arrival},'retained geometry does not make a lone Home entry eligible');
    is_deeply(plans($s),[],'no opening after reset without a new trip');
    my ($view)=GP_GetData($c,'GP','explain','Geo.Test','debug');
    is($view->{debug_reset_keep_geometry},1,'client can check support before starting tests');
    is_deeply(\@commands,[],'no actuator commands');
    is_deeply(\@messages,[],'no notifications');
    GeoPresence_Set($c,'GP','debugReset','Geo.Test');
    ok(!GP_HasGeometry(GP_Geometry($c,'Geo.Test','Z.Work',1)),'explicit full reset still discards unsaved geometry');
};

subtest 'retaining geometry cannot clear conflicts or reuse synthetic clock timestamps' => sub {
    my ($c,$cfg,$s)=fixture();
    my $rt=$c->{helper}{gp};
    $rt->{geometry}{debug}{'Geo.Test'}{'Z.Work'}{blocked}=1;
    like(GeoPresence_Set($c,'GP','debugReset','Geo.Test','keepGeometry'),qr/geometry retained/,'retain conflicted metadata too');
    ok(!GP_Config($c,'Geo.Test',1)->{geometry_ready},'reset cannot remove a geometry conflict');
    my $state=GP_State($c,'Geo.Test',1);
    like(GeoPresence_Set($c,'GP','debugReset','Geo.Test','invalid'),qr/Usage/,'unsupported option rejected');
    like(GeoPresence_Set($c,'GP','debugReset','Geo.Test','keepGeometry','extra'),qr/Usage/,'extra arguments rejected');
    is(GP_State($c,'Geo.Test',1),$state,'bad command did not reset the state');
    GeoPresence_Set($c,'GP','debugAdvance','Geo.Test',180);
    like(GeoPresence_Set($c,'GP','debugReset','Geo.Test','keepGeometry'),qr/real-time debug session/,'synthetic time needs explicit full reset');
    is($state->{debug_offset},180,'rejection leaves current session intact');
    GeoPresence_Set($c,'GP','debugReset','Geo.Test');
    ok(!GP_State($c,'Geo.Test',1)->{debug_offset},'full reset clears synthetic clock');
};

subtest 'explicit geometry confirmation survives activation without promoting a debug trip' => sub {
    my ($c,$cfg,$s)=fixture('geofency_phone');
    $defs{GP}{READINGS}{mode}{VAL}='active'; # One resident can prepare geometry while others operate.
    delete $defs{'Z.Work'}{READINGS}{gp_geometry};
    delete $c->{helper}{gp}{geometry}{debug}{'Geo.Test'}{'Z.Work'};
    GP_UpdateGeometry($c,'Geo.Test',1,$s,{kind=>'geo',zone=>'Z.Work',time=>$now,received=>$now,
        geometry=>{lat=>0.1,lon=>0,radius=>150}},$cfg,$now);
    $cfg=GP_Config($c,'Geo.Test',1);
    event($s,$cfg,'Outer',0);advance(61);event($s,$cfg,'Home',1,'walking');
    ok($s->{trip}{armed} && $s->{arrival},'simulation has a qualified trip and a pending arrival');
    my $rt=$c->{helper}{gp};
    $rt->{prod}{'Geo.Other'}={trip=>{armed=>1}};
    $rt->{actors}{door}={waiters=>{'Geo.Other'=>1},start=>$now};
    $rt->{queue}=[{resident=>'Geo.Test',debug=>1},{resident=>'Geo.Other',debug=>0}];
    my $before=$defs{'Z.Home'}{READINGS}{gp_geometry}{VAL};
    my $applied;
    {
        no warnings 'redefine';
        local *readingsBeginUpdate=sub {die 'Unexpected reading callback'};
        $applied=GeoPresence_Set($c,'GP','applyGeometry','Geo.Test');
    }
    like($applied,qr/Geometry applied for 1 location/, 'only new geometry committed with controller active');
    is($defs{'Z.Home'}{READINGS}{gp_geometry}{VAL},$before,'unchanged geometry keeps its original metadata');
    my $stored=JSON::PP::decode_json($defs{'Z.Work'}{READINGS}{gp_geometry}{VAL});
    is($stored->{radius},150,'geometry stored in an ordinary reading');
    ok(!exists($stored->{entry}) && !exists($stored->{motion}) && !exists($stored->{trip}),'no observation or trip copied');
    ok(!exists($rt->{prod}{'Geo.Test'}) && !exists($rt->{debug}{'Geo.Test'}),'both own journeys discarded');
    is_deeply($rt->{queue},[{resident=>'Geo.Other',debug=>0}],'own pending observations discarded');
    ok($rt->{prod}{'Geo.Other'}{trip}{armed} && $rt->{actors}{door}{waiters}{'Geo.Other'},'other residents and actor feedback remain intact');
    is(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','mode','active'),undef,'operator can activate resident after confirmation');
    is(GP_Config($c,'Geo.Test',0)->{zones}{'Z.Work'}{radius},150,'production sees confirmed geometry after mode reset');
    is(GP_Config($c,'Geo.Test',1)->{zones}{'Z.Work'}{radius},150,'debug also starts from stored geometry after mode reset');
    my ($validation)=GP_GetData($c,'GP','validate','Geo.Test');
    is_deeply($validation->{warnings},[],'productive validation no longer reports missing place geometry');
    GP_ResetController($c);
    is(GP_Config($c,'Geo.Test',0)->{zones}{'Z.Work'}{radius},150,'reload restores confirmed geometry from reading');
    my $prod=GP_State($c,'Geo.Test',0);advance(40);
    event($prod,GP_Config($c,'Geo.Test',0),'Home',1,'walking');
    ok(!$prod->{trip} && !$prod->{arrival},'saved geometry alone cannot qualify a return');
    is_deeply(plans($prod),[],'no arrival opening without a new departure');
    is_deeply(\@commands,[],'confirmation dispatches no commands');
    is_deeply(\@messages,[],'confirmation sends no messages');
};

subtest 'geometry confirmation validates the complete set before writing any readings' => sub {
    for my $case (qw(missing blocked device zone nesting future metadata older same_time)) {
        my ($c,$cfg,$s)=fixture();
        my $rt=$c->{helper}{gp};
        my $g=$rt->{geometry}{debug}{'Geo.Test'}{'Z.Work'};
        $g->{time}=$now;$g->{changed}=$now;
        $g->{radius}=150;
        $rt->{geometry}{debug}{'Geo.Test'}{'Z.Helper'}{radius}=175; # Would otherwise be a valid update.
        $rt->{geometry}{debug}{'Geo.Test'}{'Z.Helper'}{time}=$now;
        if ($case eq 'missing') {$rt->{geometry}{debug}{'Geo.Test'}{'Z.Work'}={};}
        if ($case eq 'blocked') {$g->{blocked}=1;}
        if ($case eq 'device') {$g->{device}='other-phone';}
        if ($case eq 'zone') {$g->{id}='other-place';}
        if ($case eq 'nesting') {$rt->{geometry}{debug}{'Geo.Test'}{'Z.Home'}{radius}=5000;}
        if ($case eq 'future') {$g->{time}=$now+3600;}
        if ($case eq 'metadata') {$g->{changed}=$g->{time}+1;}
        if ($case eq 'older' || $case eq 'same_time') {
            $g->{time}=$now-1040-($case eq 'older'?1:0);$g->{changed}=$g->{time};
        }
        my %before=map {$_=>$defs{$_}{READINGS}{gp_geometry}{VAL}} grep {/^Z\./} keys %defs;
        like(GeoPresence_Set($c,'GP','applyGeometry','Geo.Test'),qr/Geometry not applied; no readings changed/,$case.' rejected');
        is_deeply({map {$_=>$defs{$_}{READINGS}{gp_geometry}{VAL}} keys %before},\%before,$case.' causes no partial write');
        is(GP_State($c,'Geo.Test',1),$s,$case.' leaves the current session untouched');
    }
};

subtest 'geometry confirmation requires an explicit real-time setup command' => sub {
    my ($c,$cfg,$s)=fixture();
    like(GeoPresence_Set($c,'GP','applyGeometry','Geo.Test','extra'),qr/Usage/,'unexpected argument rejected');
    {
        local $defs{GP}{READINGS}{mode}{VAL}='active';local $defs{'Geo.Test'}{READINGS}{mode}{VAL}='active';
        like(GeoPresence_Set($c,'GP','applyGeometry','Geo.Test'),qr/requires debug mode/,'cannot change an active resident');
    }
    {
        local $c->{helper}{gp}{learning}{'Geo.Test'}=1;
        like(GeoPresence_Set($c,'GP','applyGeometry','Geo.Test'),qr/Confirm learning/,'finish learning before confirmation');
    }
    GeoPresence_Set($c,'GP','debugAdvance','Geo.Test',180);
    like(GeoPresence_Set($c,'GP','applyGeometry','Geo.Test'),qr/real-time observations/,'synthetic clock must not seed production');
    ($c)=fixture('phone_only');
    like(GeoPresence_Set($c,'GP','applyGeometry','Geo.Test'),qr/Geofency resident/,'phone-only has no geometry to confirm');
};

done_testing;
