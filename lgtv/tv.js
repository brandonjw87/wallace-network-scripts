// LG webOS TV control. Usage: node tv.js <cmd> [arg]
// cmds: pair, info, on, off, vol <0-100|up|down>, mute <true|false>, apps, launch <appId>, inputs, input <inputId>, toast <text>, key <HOME|BACK|ENTER|UP|DOWN|LEFT|RIGHT|PLAY|PAUSE>
const fs=require('fs'),path=require('path');
const IP=process.env.TV_IP||'192.0.2.21', MAC='00:00:5E:00:53:03';
const [,,cmd,arg]=process.argv;
if(cmd==='on'){ require('wake_on_lan').wake(MAC,{address:'192.0.2.27'},e=>{console.log(e?'wake err '+e:'wake sent');}); return; }
const lgtv=require('lgtv2')({url:`wss://${IP}:3001`,keyFile:path.join(__dirname,'client-key'),timeout:8000,reconnect:0,wsconfig:{tlsOptions:{rejectUnauthorized:false}}});
process.env.NODE_TLS_REJECT_UNAUTHORIZED='0';
const done=(e,r)=>{ console.log(e?('ERR '+(e.message||JSON.stringify(e))):JSON.stringify(r,null,1)); lgtv.disconnect(); setTimeout(()=>process.exit(e?1:0),300); };
const req=(u,p)=>lgtv.request(u,p||{},done);
lgtv.on('error',e=>{console.log('ERR connect '+(e.message||e)); process.exit(1);});
lgtv.on('prompt',()=>console.log('Accept the prompt on the TV with the remote...'));
lgtv.on('connect',()=>{
 switch(cmd){
  case 'pair': case 'info': return req('ssap://system/getSystemInfo');
  case 'off': return req('ssap://system/turnOff');
  case 'vol': if(arg==='up')return req('ssap://audio/volumeUp'); if(arg==='down')return req('ssap://audio/volumeDown'); if(arg)return req('ssap://audio/setVolume',{volume:+arg}); return req('ssap://audio/getVolume');
  case 'mute': return req('ssap://audio/setMute',{mute:arg!=='false'});
  case 'apps': return lgtv.request('ssap://com.webos.applicationManager/listLaunchPoints',{},(e,r)=>done(e,r&&r.launchPoints.map(a=>({id:a.id,title:a.title}))));
  case 'launch': return req('ssap://system.launcher/launch',{id:arg});
  case 'inputs': return lgtv.request('ssap://tv/getExternalInputList',{},(e,r)=>done(e,r&&r.devices.map(d=>({id:d.id,label:d.label,connected:d.connected}))));
  case 'input': return req('ssap://tv/switchInput',{inputId:arg});
  case 'toast': return req('ssap://system.notifications/createToast',{message:arg||'Hello from Grok Bot'});
  case 'current': return req('ssap://com.webos.applicationManager/getForegroundAppInfo');
  case 'key': return lgtv.getSocket('ssap://com.webos.service.networkinput/getPointerInputSocket',(e,s)=>{ if(e)return done(e); s.send('button',{name:(arg||'HOME').toUpperCase()}); setTimeout(()=>done(null,{key:arg}),400); });
  default: done({message:'unknown cmd'});
 }
});
