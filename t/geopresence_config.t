use strict;
use warnings;
use Test::More;
use FindBin;
use POSIX qw(strftime);
use Scalar::Util qw(refaddr);

our (%defs,%attr,%data,%keys,$init_done,$readingFnAttributes,$unicodeEncoding);
our ($now,$mono,@commands,@messages);
$readingFnAttributes=''; $unicodeEncoding=1;
sub InternalTimer { }
sub RemoveInternalTimer { }
sub Log3 { }
sub setNotifyDev { $_[0]{NOTIFYDEV}=$_[1]; }
sub deviceEvents { $_[0]{CHANGED}; }
sub setReadingsVal { $_[0]{READINGS}{$_[1]}={VAL=>$_[2],TIME=>$_[3]}; }
sub readingsBeginUpdate { }
sub readingsBulkUpdate { setReadingsVal($_[0],$_[1],$_[2],stamp()); }
sub readingsEndUpdate { }
sub CommandSet { push @commands,$_[1]; return; }
sub pushMsg { push @messages,[@_]; }
sub getKeyValue { (undef,$keys{$_[0]}); }
sub setKeyValue { $keys{$_[0]}=$_[1]; return; }
require "$FindBin::Bin/../FHEM/98_GeoPresence.pm";
{
    no warnings qw(redefine once);
    *GP_Now=sub {$now}; *GP_Mono=sub {$mono};
    *GP_EnsureHTTP=sub {return;}; # Real sockets are covered by the integration suite.
}
sub stamp { strftime('%Y-%m-%d %H:%M:%S',localtime($now)); }
sub advance { $now+=$_[0]; $mono+=$_[0]; }
sub global_event { GeoPresence_Notify($defs{GP},{NAME=>'global',CHANGED=>[@_]}); }
sub define {
    my ($name,$definition)=@_;
    my $d=$defs{$name}={NAME=>$name,TYPE=>'GeoPresence'};
    my $error=GeoPresence_Define($d,"$name GeoPresence $definition");
    die $error if defined $error;
    global_event("DEFINED $name") if $init_done;
    return $d;
}
sub attribute {
    my ($name,$key,$value)=@_;
    my $error=GeoPresence_Attr(defined($value)?'set':'del',$name,$key,$value);
    return $error if defined $error;
    defined($value) ? ($attr{$name}{$key}=$value) : delete($attr{$name}{$key});
    global_event(defined($value)?"ATTR $name $key $value":"DELETEATTR $name $key") if $init_done;
    return;
}
sub fixture {
    %defs=(); %attr=(); %data=(); %keys=(); @commands=(); @messages=();
    $now=1790000000; $mono=1000; $init_done=0;
    my $c=define('GP','controller'); GP_StoreMode($c,'active');
    for my $person (qw(A B)) {
        my $r="Geo.$person"; my $rr="rr_$person";
        $defs{$rr}={NAME=>$rr,TYPE=>'ROOMMATE',READINGS=>{state=>{VAL=>'absent',TIME=>stamp()}}};
        $attr{$rr}{rr_locationUnderway}='underway';
        define($r,"resident GP $rr");
        $attr{$r}={sourceMode=>'geofency_only',deviceId=>"phone-$person",webhookUser=>"user-$person"};
        $keys{"GeoPresence_${r}_auth"}='a'x32 . ':'.'b'x64;
        GP_StoreMode($defs{$r},'active');
        for my $zone ([Home=>'home',0,50],[Outer=>'outer',0,4500],[Work=>'place',0.1,100]) {
            my ($name,$role,$lat,$radius)=@$zone;
            my $n="$person.$name";
            define($n,"location $r $role");
            $attr{$n}={zoneId=>lc($name),groups=>$name};
            $defs{$n}{READINGS}{gp_geometry}{VAL}=JSON::PP::encode_json({lat=>$lat,lon=>0,radius=>$radius,
                device=>lc("phone-$person"),id=>lc($name),time=>$now-1000,changed=>$now-1000,blocked=>0});
        }
    }
    define('Message','action GP notify');
    $attr{Message}={message=>'%resident% is home',priority=>0,channel=>0,room=>'UI',target=>'unused-old-setting'};
    for my $n (qw(Rule1 Rule2)) {
        define($n,'rule GP');
        $attr{$n}={residents=>'Geo.A,Geo.B',trigger=>'enter',locationGroup=>'Home',action=>'Message',cooldown=>0};
    }
    $init_done=1; global_event('INITIALIZED'); GeoPresence_Timer($c);
    return $c;
}

subtest 'idle ticks reuse static configuration and validation for all residents' => sub {
    my $c=fixture();
    is_deeply([GP_Validate($c)],[],'fixture is valid');
    my ($builds,$rules)=(0,0);
    my $build=\&GP_ValidateAction; my $rule=\&GP_ValidateRule;
    {
        no warnings 'redefine';
        local *GP_ValidateAction=sub {$builds++; $build->(@_)};
        local *GP_ValidateRule=sub {$rules++; $rule->(@_)};
        for (1..20) {advance(1); GeoPresence_Timer($c);}
    }
    is($builds,0,'no repeated adapter validation');
    is($rules,0,'no repeated static rule validation');
    my ($stats)=GP_GetData($c,'GP','timerStats');
    is($stats->{last_device_scans},0,'no idle catalogue scan');
    is($stats->{last_config_builds},0,'no idle configuration build');
    $c->{helper}{gp_http_error}='Listener unavailable';
    like(join('; ',GP_Validate($c,'Geo.A')),qr/Listener unavailable/,'runtime transport failure remains live');
    delete $c->{helper}{gp_http_error};
    is_deeply([GP_Validate($c,'Geo.A')],[],'transport recovery needs no static rebuild');
};

subtest 'rules, residents and plans share only applicable adapter parameters' => sub {
    my $c=fixture();
    my $a=GP_Config($c,'Geo.A'); my $b=GP_Config($c,'Geo.B',1);
    my $params=$a->{rules}[0]{params};
    is_deeply($params,{message=>'%resident% is home',priority=>0,channel=>0},'cosmetic and obsolete adapter fields are excluded');
    is(refaddr($a->{rules}[1]{params}),refaddr($params),'second rule shares the descriptor');
    is(refaddr($b->{rules}[0]{params}),refaddr($params),'second resident and debug pool share the descriptor');
    my $s=GP_NewState($now,$mono,'plan','geofency_only');
    GP_Rules($s,$a,'enter',{zone=>'A.Home',group=>'Home',selector=>'group:Home',time=>$now,received=>$now},$now,$mono);
    is(scalar @{$s->{intents}},1,'matching rules consume one notification');
    is(refaddr($s->{intents}[0]{params}),refaddr($params),'plan retains the same immutable parameters');
};

subtest 'cosmetic edits preserve checkpoint binding across reload' => sub {
    my $c=fixture(); advance(40);
    my $cfg=GP_Config($c,'Geo.A'); my $s=GP_State($c,'Geo.A',0);
    GP_Process($s,$cfg,{kind=>'geo',zone=>'A.Work',entry=>0,time=>$now,received=>$now,key=>'work-exit'},$now,$mono);
    GP_Checkpoint($c,'Geo.A',$cfg,$s);
    my $checkpoint=JSON::PP::decode_json(GP_Read('Geo.A','gp_trip_checkpoint','{}'));
    is($checkpoint->{status},'qualified','qualified trip persisted');
    my $revision=GP_ResumeRevision($c,'Geo.A',$cfg);
    is(attribute('Message','room','Other room'),undef,'cosmetic edit is allowed during active operation');
    is(GP_ResumeRevision($c,'Geo.A',GP_Config($c,'Geo.A')),$revision,'cosmetic edit preserves binding');
    advance(1); GP_ResetController($c,'resume');
    $c->{helper}{gp}{ready}=1;
    my $restored=GP_State($c,'Geo.A',0);
    is($restored->{trip}{id},$checkpoint->{trip}{id},'trip resumes with its original identifier');
    is(scalar @commands,0,'reload produces no commands');
    is(scalar @messages,0,'reload produces no notifications');
};

subtest 'ordinary version 1 checkpoints retain their pre-R01 binding' => sub {
    my $c=fixture();
    delete @{$attr{Message}}{qw(room target)};
    # Generated with the module before R-01 for this fixture, using only the
    # adapter's supported attributes. No dependency on the new hash builder.
    my $legacy_revision='54091508a3b8828224c7659f66f0050c24fd0df9ec73caa5f97e7b41c529cfc3';
    my $cfg=GP_Config($c,'Geo.A');
    is(GP_ResumeRevision($c,'Geo.A',$cfg),$legacy_revision,'unchanged semantic configuration preserves the old binding');
    advance(40); my $s=GP_State($c,'Geo.A',0);
    GP_Process($s,$cfg,{kind=>'geo',zone=>'A.Work',entry=>0,time=>$now,received=>$now,key=>'old-trip'},$now,$mono);
    GP_Checkpoint($c,'Geo.A',$cfg,$s);
    my $checkpoint=JSON::PP::decode_json(GP_Read('Geo.A','gp_trip_checkpoint',''));
    $checkpoint->{version}=1;
    delete @{$checkpoint->{state}}{qw(action_visits action_last)};
    @{$checkpoint->{state}}{qw(notify_seen notify_order notify_last)}=({},[],{});
    $defs{'Geo.A'}{READINGS}{gp_trip_checkpoint}{VAL}=JSON::PP::encode_json($checkpoint);
    # Simulate process loss without reserializing a live journey during reload.
    delete $c->{helper}{gp}{prod}{'Geo.A'};
    advance(1); GP_ResetController($c,'resume');
    $c->{helper}{gp}{ready}=1;
    my $restored=GP_State($c,'Geo.A',0);
    ok($restored->{trip}{armed},'qualified checkpoint is accepted with the unchanged version 1 binding');
};

subtest 'geometry invalidates only changed coordinates in the affected pool' => sub {
    my $c=fixture(); advance(40);
    my $cfg=GP_Config($c,'Geo.A'); my $debug=GP_Config($c,'Geo.A',1); my $other=GP_Config($c,'Geo.B');
    my $s=GP_State($c,'Geo.A',0);
    my $e={kind=>'geo',zone=>'A.Home',entry=>1,key=>'geometry',time=>$now,received=>$now,
        geometry=>{lat=>0,lon=>0,radius=>50}};
    is(GP_UpdateGeometry($c,'Geo.A',0,$s,$e,$cfg,$now),'same','same coordinates with newer time');
    is(refaddr(GP_Config($c,'Geo.A')),refaddr($cfg),'timestamp update retains configuration');
    $e={%$e,time=>$now+1,geometry=>{lat=>0,lon=>0,radius=>60}}; advance(1);
    is(GP_UpdateGeometry($c,'Geo.A',0,$s,$e,$cfg,$now),'changed','changed radius is detected');
    is(GP_Config($c,'Geo.A')->{zones}{'A.Home'}{radius},60,'affected view receives new geometry');
    is(refaddr(GP_Config($c,'Geo.A',1)),refaddr($debug),'debug configuration remains separate');
    is(refaddr(GP_Config($c,'Geo.B')),refaddr($other),'other resident retains its view');
};

subtest 'accepted edits commit before rebuild and rejected edits retain the active snapshot' => sub {
    my $c=fixture();
    my $cfg=GP_Config($c,'Geo.A');
    like(attribute('Geo.A','allowDoor',1),qr/active residents/,'active resident cannot be reconfigured');
    is(refaddr(GP_Config($c,'Geo.A')),refaddr($cfg),'rejected edit preserves the snapshot');
    is(GeoPresence_Set($defs{'Geo.A'},'Geo.A','mode','debug'),undef,'only affected resident pauses');
    my $other=GP_State($c,'Geo.B',0);
    is(attribute('Geo.A','allowDoor',1),undef,'debug resident accepts edit');
    is(GP_Config($c,'Geo.A')->{allowDoor},1,'rebuilt configuration sees committed value');
    is(refaddr(GP_State($c,'Geo.B',0)),refaddr($other),'unrelated resident session survives');
    GP_StoreMode($c,'debug');
    is(attribute('GP','action_max_age',10),undef,'compatible age change accepted');
    my $before=GP_Config($c,'Geo.A');
    like(attribute('GP','reorder_window',10),qr/smaller than action_max_age/,'incompatible proposed window rejected');
    is(refaddr(GP_Config($c,'Geo.A')),refaddr($before),'invalid timing does not publish another snapshot');
    attribute('GP','action_max_age',200); attribute('GP','reorder_window',120);
    like(attribute('GP','action_max_age',undef),qr/smaller than action_max_age/,'deletion cannot restore an incompatible default');
    is($attr{GP}{action_max_age},200,'rejected deletion retains the configured age');
    is(attribute('GP','reorder_window',undef),undef,'restoring the short default window is allowed');
    is(attribute('GP','action_max_age',undef),undef,'default age is compatible again');
};

subtest 'external references, names and dependent attributes refresh cached checks' => sub {
    my $c=fixture();
    is_deeply([GP_Validate($c,'Geo.A')],[],'reference initially valid');
    delete $defs{rr_A}; global_event('DELETED rr_A');
    like(join('; ',GP_Validate($c,'Geo.A')),qr/missing or invalid ROOMMATE/,'deletion invalidates cached reference validation');
    $defs{rr_A}={NAME=>'rr_A',TYPE=>'dummy'}; global_event('DEFINED rr_A');
    like(join('; ',GP_Validate($c,'Geo.A')),qr/missing or invalid ROOMMATE/,'wrong replacement type remains invalid');
    $defs{rr_A}{TYPE}='ROOMMATE'; global_event('MODIFIED rr_A');
    is_deeply([GP_Validate($c,'Geo.A')],[],'type correction refreshes validation');
    $attr{rr_A}{alias}='New name'; global_event('ATTR rr_A alias New name');
    is(GP_Config($c,'Geo.A')->{label},'New name','dependent label is refreshed');
    $defs{rr_New}=delete $defs{rr_A}; $defs{rr_New}{NAME}='rr_New'; global_event('RENAMED rr_A rr_New');
    like(join('; ',GP_Validate($c,'Geo.A')),qr/missing or invalid ROOMMATE/,'rename cannot leave a cached valid old reference');
};

subtest 'learning confirmation refreshes geometry queried by a synchronous callback' => sub {
    my $c=fixture(); advance(40);
    like(GP_BeginLearning($c,'Geo.A'),qr/Learning for 15 minutes/,'learning window is open');
    my $learned=$c->{helper}{gp}{learned}{'Geo.A'};
    $learned->{zones}{home}={id=>'home',name=>'Home',number=>1,time=>$now,
        geometry=>{lat=>0,lon=>0,radius=>60}};
    my $update=\&GP_UpdateModes; my $before;
    {
        no warnings 'redefine';
        local *GP_UpdateModes=sub {
            $update->(@_);
            $before=GP_Config($c,'Geo.A',1)->{zones}{'A.Home'}{radius};
        };
        like(GP_LearnConfirm($c,'Geo.A'),qr/Learning confirmed/,'setup is explicitly confirmed');
    }
    is($before,50,'callback queried the previous unconfirmed geometry');
    is(GP_Config($c,'Geo.A',1)->{zones}{'A.Home'}{radius},60,'confirmed geometry replaces the earlier debug view');
    is(GP_Config($c,'Geo.A',0)->{zones}{'A.Home'}{radius},50,'production geometry remains unchanged');
};

subtest 'reports reuse their prepared configuration without allocating journey state' => sub {
    my $c=fixture(); GP_ResetResident($c,'Geo.A');
    my $calls=0; my $config=\&GP_Config;
    {
        no warnings 'redefine';
        local *GP_Config=sub {$calls++; $config->(@_)};
        like(GeoPresence_Get($c,'GP','explain','Geo.A','format=text'),qr/PRODUCTION/,'complete text report is available');
    }
    is($calls,1,'data and renderer use the same snapshot');
    ok(!exists $c->{helper}{gp}{prod}{'Geo.A'},'report does not allocate a journey');
    is(scalar @commands,0,'report emits no commands');
};

subtest 'GP-R01-001: saved timing pairs load independently of attribute order' => sub {
    my $c=fixture();
    for my $order ([action_max_age=>2,reorder_window=>1],[reorder_window=>1,action_max_age=>2]) {
        {
            local $init_done=0;
            delete @{$attr{GP}}{qw(action_max_age reorder_window)};
            for (my $i=0;$i<@$order;$i+=2) {
                is(attribute('GP',$order->[$i],$order->[$i+1]),undef,'individual saved value accepted while loading');
            }
            global_event('REREADCFG');
        }
        my $cfg=GP_Config($c,'Geo.A');
        is($cfg->{action_max_age},2,'saved action age is retained');
        is($cfg->{reorder_window},1,'saved reorder window is retained');
        is_deeply([GP_Validate($c)],[],'complete restored pair validates');
    }
    {
        local $init_done=0;
        attribute('GP','action_max_age',1); attribute('GP','reorder_window',2);
        global_event('REREADCFG');
    }
    GeoPresence_Timer($c);
    like(join('; ',@{$c->{helper}{gp}{errors}{'Geo.A'}}),qr/smaller than action_max_age/,
        'invalid complete pair blocks processing after restoration');
    is($attr{GP}{action_max_age},1,'invalid configuration is reported without replacing its value by a default');
};

subtest 'GP-R01-002: cold administrative edits never compile discarded catalogues' => sub {
    my $c=fixture();
    GP_InvalidateConfig($c);
    my $calls=0; my $catalog=\&GP_Catalog;
    {
        no warnings 'redefine';
        local *GP_Catalog=sub {$calls++; $catalog->(@_)};
        like(attribute('Message','priority',1),qr/Geo.A.*Geo.B/,'cold dependency index protects all active residents');
        is(GeoPresence_Set($c,'GP','mode','debug'),undef,'controller pauses without compiling configuration');
        GP_ResetController($c,'resume');
        for my $value (1,0) {
            is(attribute('Geo.A','allowDoor',$value),undef,'resident edit');
            is(attribute('Message','priority',$value),undef,'shared action edit');
            is(attribute('Rule1','cooldown',$value),undef,'rule edit');
            is(attribute('A.Home','label',"Home $value"),undef,'location edit');
            is(attribute('GP','future_tolerance',30+$value),undef,'controller edit');
        }
        {
            local $init_done=0;
            attribute('Geo.A','allowDoor',1); attribute('Message','priority',1);
            global_event('REREADCFG');
        }
    }
    is($calls,0,'administration and restoration do not build full intermediate catalogues');
    ok(!$c->{helper}{gp_config},'full configuration is still deferred');
    is(GP_Config($c,'Geo.A')->{allowDoor},1,'next real consumer sees the committed configuration');
};

subtest 'GP-R01-003: unrelated MODIFIED events do no inventory or widget work' => sub {
    my $c=fixture();
    $defs{Unrelated}={NAME=>'Unrelated',TYPE=>'dummy'};
    my ($inventory,$catalog)=@{$c->{helper}}{qw(gp_devices gp_config)};
    my ($scans,$widgets)=(0,0);
    my $scan=\&GP_Inventory; my $update=\&GP_UpdateAttrLists;
    {
        no warnings 'redefine';
        local *GP_Inventory=sub {$scans++; $scan->(@_)};
        local *GP_UpdateAttrLists=sub {$widgets++; $update->(@_)};
        global_event('MODIFIED Unrelated') for 1..5;
        is(refaddr($c->{helper}{gp_config}),refaddr($catalog),'unrelated events retain the prepared catalogue');
        global_event('MODIFIED rr_A');
    }
    is($scans,0,'Notify never enumerates devices for modify');
    is($widgets,0,'modify never rebuilds unchanged widget choices');
    is(refaddr($c->{helper}{gp_devices}),refaddr($inventory),'membership inventory is retained');
    ok(!$c->{helper}{gp_config},'dependent modify still invalidates its static checks');
    GP_Config($c,'Geo.A');
    my $current=$c->{helper}{gp_config};
    global_event('MODIFIED Unrelated');
    is(refaddr($c->{helper}{gp_config}),refaddr($current),'unrelated modify retains full configuration');
};

subtest 'GP-R01-003: PRESENCE choices follow definition, rename and deletion' => sub {
    my $c=fixture(); GP_StoreMode($c,'debug');
    $defs{Phone1}={NAME=>'Phone1',TYPE=>'PRESENCE'};
    attribute('Geo.A','sourceMode','phone_only'); attribute('Geo.A','phoneProxies','Phone1');
    GP_UpdateAttrLists();
    unlike($defs{'Geo.A'}{'.AttrList'},qr/Phone2/,'new proxy is initially absent');
    $defs{Phone2}={NAME=>'Phone2',TYPE=>'PRESENCE'}; global_event('DEFINED Phone2');
    like($defs{'Geo.A'}{'.AttrList'},qr/Phone2/,'defined PRESENCE is offered');
    $defs{Phone3}=delete $defs{Phone2}; $defs{Phone3}{NAME}='Phone3'; global_event('RENAMED Phone2 Phone3');
    like($defs{'Geo.A'}{'.AttrList'},qr/Phone3/,'renamed PRESENCE is offered');
    unlike($defs{'Geo.A'}{'.AttrList'},qr/Phone2/,'old proxy name is removed');
    delete $defs{Phone3}; global_event('DELETED Phone3');
    unlike($defs{'Geo.A'}{'.AttrList'},qr/Phone3/,'deleted PRESENCE is removed');
};

subtest 'GP-R01-004: exact diagnostic edits retain configuration, bulk deletions invalidate it' => sub {
    my $c=fixture(); GP_StoreMode($c,'debug');
    my $catalog=$c->{helper}{gp_config};
    for my $spec ([debugLog=>1],[logFile=>'/tmp/geopresence-review-diagnostic-%Y.log']) {
        my ($key,$value)=@$spec;
        is(attribute('GP',$key,$value),undef,"set $key");
        is(refaddr($c->{helper}{gp_config}),refaddr($catalog),"setting $key retains configuration");
        is(attribute('GP',$key,undef),undef,"delete $key");
        is(refaddr($c->{helper}{gp_config}),refaddr($catalog),"deleting $key retains configuration");
    }
    attribute('GP','reorder_window',10); GP_Config($c,'Geo.A');
    delete $attr{GP}{reorder_window}; global_event('DELETEATTR GP .*_window');
    ok(!$c->{helper}{gp_config},'pattern deletion of functional attributes invalidates configuration');
    is(GP_Config($c,'Geo.A')->{reorder_window},2,'next consumer sees the default window');
    $attr{GP}={}; global_event('DELETEATTR GP');
    ok(!$c->{helper}{gp_config},'deleting all attributes invalidates configuration');
};

done_testing;
