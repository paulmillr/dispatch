#!/usr/bin/env python3
"""Run against a dedicated test VM, using existing herdr and Rust example binaries."""
import argparse,select,struct,json,os,pathlib,socket,subprocess,tempfile,time,uuid
parser=argparse.ArgumentParser(description='Isolated real-herdr framed-controller regression probe')
parser.add_argument('--herdr', required=True, help='Existing herdr executable; never installed or upgraded')
parser.add_argument('--controller', action='append', required=True, help='Built herdr-stream example (repeat for architectures)')
args=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='hcontroller-',dir='/tmp') as directory:
 path=directory+'/herdr/herdr.sock';pathlib.Path(path).parent.mkdir()
 env=dict(os.environ,XDG_CONFIG_HOME=directory,HERDR_SOCKET_PATH=path,HERDR_SESSION='default')
 server=subprocess.Popen([str(pathlib.Path(args.herdr).resolve()),'server'],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 def rpc(method,**params):
  ident=uuid.uuid4().hex
  with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
   client.settimeout(3);client.connect(path)
   client.sendall(json.dumps({'id':ident,'method':method,'params':params}).encode()+b'\n')
   data=b''
   while b'\n' not in data:
    chunk=client.recv(8192)
    assert chunk,'unexpected server EOF'
    data+=chunk
  reply=json.loads(data);assert reply['id']==ident and 'error' not in reply,reply
  return reply['result']
 try:
  for _ in range(100):
   if pathlib.Path(path).exists():break
   assert server.poll() is None;time.sleep(.05)
  registry=pathlib.Path.home()/'.dispatch-ssh'
  for index,controller in enumerate(args.controller):
   arch='controller-'+str(index)
   cwd=pathlib.Path(directory)/arch;cwd.mkdir()
   workspace=rpc('workspace.create',cwd=str(cwd),focus=True)
   pane=workspace['root_pane'];shell=rpc('pane.process_info',pane_id=pane['pane_id'])['process_info']['shell_pid']
   before=set(registry.iterdir()) if registry.exists() else set()
   for mode in ['normal', 'cancel', 'eof', 'wrong-id', 'invalid-control', 'truncated-control', 'credit-overrun']:
    client=subprocess.Popen([str(pathlib.Path(controller).resolve()),'default',pane['terminal_id']],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    pending=bytearray(); deadline=time.monotonic()+8
    def send(kind,payload=b''):
     client.stdin.write(struct.pack('>IBI',len(payload)+5,ord(kind),1)+payload);client.stdin.flush()
    def readframe():
     while True:
      assert time.monotonic()<deadline,'framed stream deadline'
      if len(pending)>=4:
       length=struct.unpack('>I',pending[:4])[0];assert 5<=length<=1048581
       if len(pending)>=length+4:
        kind=chr(pending[4]);ident=struct.unpack('>I',pending[5:9])[0];assert ident==1
        body=bytes(pending[9:length+4]);del pending[:length+4];return kind,body
      ready,_,_=select.select([client.stdout],[],[],.05)
      if ready:
       chunk=os.read(client.stdout.fileno(),65536)
       assert chunk,('unexpected EOF',client.poll(),client.stderr.read())
       pending.extend(chunk)
    try:
     assert readframe()==('J',b'{"ready":true}')
     kind,body=readframe();assert kind=='W' and struct.unpack('>I',body)[0]==1048576
     while readframe()[0]!='D':pass
     if mode=='cancel':
      send('C');client.wait(timeout=3);assert client.returncode==0
     elif mode=='eof':
      client.stdin.close();client.wait(timeout=3);assert client.returncode==0
     elif mode in ['wrong-id', 'invalid-control', 'truncated-control', 'credit-overrun']:
      if mode=='wrong-id':
       client.stdin.write(struct.pack('>IBI',5,ord('E'),2));client.stdin.flush()
      elif mode=='invalid-control':send('D',b'{"type":"exec","command":"false"}\n')
      elif mode=='truncated-control':send('D',b'{"type":');send('E')
      else:send('D',b' '*1048576);send('D',b' ')
      client.wait(timeout=3);assert client.returncode!=0
     else:
      control=(json.dumps({'type':'terminal.resize','cols':100,'rows':30})+'\n'+json.dumps({'type':'terminal.input','text':'printf FRAMED_OK > framed-proof; printf FRAMED_OK\r'})+'\n').encode()
      # Exercise fragments inside a JSON line, across separate protocol frames.
      for chunk in [control[:13],control[13:29],control[29:]]:send('D',chunk)
      credit=0
      while credit<len(control):
       kind,body=readframe()
       if kind=='W':credit+=struct.unpack('>I',body)[0]
      while not (cwd/'framed-proof').exists():
       assert time.monotonic()<deadline;time.sleep(.02)
      assert (cwd/'framed-proof').read_text()=='FRAMED_OK'
      send('E')
      saw_exit=False
      while True:
       kind,body=readframe()
       if kind=='X':assert json.loads(body)['status']==0;saw_exit=True
       if kind=='E':assert saw_exit;break
      client.wait(timeout=3);assert client.returncode==0
    finally:
     if client.poll() is None:client.kill();client.wait(timeout=3)
     client.stdin.close();client.stdout.close();client.stderr.close()
   os.kill(shell,0)
   assert rpc('pane.get',pane_id=pane['pane_id'])['pane']['terminal_id']==pane['terminal_id']
   assert (set(registry.iterdir()) if registry.exists() else set()) == before,'private relay registry leaked'
   print(arch,'framed rendering, fragmented input, credit, half-close, exit, cancellation, EOF, invalid requests and registry cleanup passed',flush=True)
   rpc('workspace.close',workspace_id=workspace['workspace']['workspace_id'])
 finally:
  server.terminate()
  try:server.wait(timeout=5)
  except subprocess.TimeoutExpired:server.kill();server.wait(timeout=5)
