process.env.NODE_TLS_REJECT_UNAUTHORIZED='0';
const lgtv=require('lgtv2')({url:'wss://192.0.2.21:3001',keyFile:__dirname+'/client-key',timeout:8000,reconnect:0});
const [,,uri,json]=process.argv;
lgtv.on('error',e=>{console.log('ERR',e.message);process.exit(1)});
lgtv.on('connect',()=>lgtv.request(uri,json?JSON.parse(require("fs").readFileSync(json,"utf8")):{},(e,r)=>{console.log(e?'ERR '+JSON.stringify(e):JSON.stringify(r));lgtv.disconnect();setTimeout(()=>process.exit(0),200)}));

