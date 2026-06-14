// CipherNest UI Kit — Interactive prototype
const { useState, useEffect } = React;

const PHOTOS = Array.from({length:18}, (_,i)=>`https://picsum.photos/seed/kit${i}/240/240`);

function Lock({ onUnlock }) {
  return (
    <PhoneShell>
      <div style={{ flex:1, display:'flex', flexDirection:'column', alignItems:'center', justifyContent:'center', gap:0, position:'relative' }}>
        <img src="../../assets/logo_mark_brass.png" style={{ width:46, position:'absolute', top:44, opacity:.9 }} />
        <div onClick={onUnlock} style={{ width:128, height:128, borderRadius:'50%', background:'var(--accent-soft)', display:'flex', alignItems:'center', justifyContent:'center', cursor:'pointer' }}>
          <span className="mi" style={{ fontSize:66, color:'var(--accent)' }}>fingerprint</span>
        </div>
        <div style={{ display:'flex', alignItems:'center', gap:8, marginTop:34, fontWeight:500 }}>
          <span className="row-thumb accent" style={{ width:26, height:26, borderRadius:8, fontSize:13 }}>M</span> maya@protonmail.com
        </div>
        <div style={{ color:'var(--fg-muted)', fontSize:14, marginTop:8 }}>Touch the sensor to unlock your vault</div>
      </div>
      <div style={{ padding:'0 32px 40px', display:'flex', flexDirection:'column', gap:14 }}>
        <Btn variant="secondary" block onClick={onUnlock}><span className="mi">password</span> Use password instead</Btn>
      </div>
    </PhoneShell>
  );
}

function Home({ onOpenPhotos, onUpload, tab, setTab, uploadOpen, onCloseUpload }) {
  return (
    <PhoneShell>
      <AppBar large title="Your Vault" trailing={<IconBtn icon="search" />} />
      <div className="hpad" style={{ marginBottom:6 }}>
        <span className="acct-chip"><span className="av">M</span> maya@protonmail.com · Drive <span className="mi" style={{ fontSize:13, color:'var(--fg-muted)' }}>expand_more</span></span>
      </div>
      <div className="screen-body" style={{ paddingBottom:96 }}>
        <div className="storagebar">
          <div className="top"><span style={{ color:'var(--fg-2)' }}><span className="mi">database</span> 38.4 GB encrypted</span><span className="muted">of 200 GB</span></div>
          <div className="meter"><i style={{ width:'9%', background:'var(--accent)' }}></i><i style={{ width:'7%', background:'#5C8CFF' }}></i><i style={{ width:'3%', background:'var(--success)' }}></i></div>
        </div>
        <div className="hpad" style={{ marginTop:18, display:'flex', flexDirection:'column', gap:12 }}>
          <VaultCard icon="image" tint="var(--accent-soft)" color="var(--accent)" title="Photos & Videos" sub="2,431 items · 31.2 GB" thumbs={PHOTOS.slice(0,3)} onClick={onOpenPhotos} />
          <VaultCard icon="description" tint="rgba(92,140,255,0.14)" color="#5C8CFF" title="Documents" sub="184 files · 4.1 GB" />
          <VaultCard icon="music_note" tint="rgba(47,191,143,0.14)" color="var(--success)" title="Audio" sub="96 tracks · 2.3 GB" />
          <VaultCard icon="folder" tint="rgba(255,178,62,0.14)" color="var(--warning)" title="Other Files" sub="312 files · 0.8 GB" />
        </div>
      </div>
      <button className="fab" onClick={onUpload}><span className="mi">add</span></button>
      <TabBar active={tab} onChange={setTab} tabs={[
        { id:'vault', icon:'encrypted', label:'Vault' },
        { id:'activity', icon:'history', label:'Activity' },
        { id:'settings', icon:'settings', label:'Settings' },
      ]} />
      {uploadOpen && <UploadSheet onClose={onCloseUpload} />}
    </PhoneShell>
  );
}

function Gallery({ onBack, onOpen, tab, setTab }) {
  return (
    <PhoneShell>
      <AppBar onBack={onBack} title="Photos" trailing={<><IconBtn icon="search" /><IconBtn icon="more_vert" /></>} />
      <div className="screen-body">
        <div className="date-header" style={{ position:'sticky', top:0, background:'color-mix(in srgb,var(--bg) 88%,transparent)', backdropFilter:'blur(12px)', zIndex:5 }}>MAY 2026</div>
        <div className="grid3">
          {PHOTOS.map((s,i)=>(
            <div className="cell" key={i} onClick={()=>onOpen(i)}><img src={s} /></div>
          ))}
        </div>
      </div>
      <TabBar active={tab} onChange={setTab} tabs={[
        { id:'pictures', icon:'image', label:'Pictures' },
        { id:'albums', icon:'grid_view', label:'Albums' },
        { id:'stories', icon:'auto_awesome', label:'Stories' },
      ]} />
    </PhoneShell>
  );
}

function Viewer({ idx, onBack }) {
  const [cur, setCur] = useState(idx);
  return (
    <PhoneShell black>
      <div style={{ position:'absolute', inset:0, display:'flex', alignItems:'center', justifyContent:'center' }}>
        <img src={`https://picsum.photos/seed/kit${cur}/900/1300`} style={{ maxWidth:'100%', maxHeight:'100%', objectFit:'contain' }} />
      </div>
      <div style={{ position:'absolute', top:0, left:0, right:0, zIndex:20, height:96, paddingTop:44, display:'flex', alignItems:'center', paddingLeft:6, paddingRight:10, background:'linear-gradient(to bottom, rgba(0,0,0,0.62), transparent)' }}>
        <IconBtn icon="arrow_back" color="#fff" onClick={onBack} />
        <div style={{ flex:1, textAlign:'center' }}><div style={{ font:'600 14px/1.2 var(--font)', color:'#fff' }}>IMG_{4800+cur}.heic</div><div style={{ fontSize:11, color:'rgba(255,255,255,0.6)', marginTop:3 }}>May 18, 2026 · 12.4 MP</div></div>
        <IconBtn icon="more_vert" color="#fff" />
      </div>
      <div style={{ position:'absolute', left:0, right:0, bottom:0, zIndex:20, padding:'18px 0 26px', background:'linear-gradient(to top, rgba(0,0,0,0.72), transparent)' }}>
        <div style={{ display:'flex', justifyContent:'space-around', padding:'0 28px 16px' }}>
          {[['share','Share'],['star','Favorite'],['info','Details'],['delete','Delete']].map(([ic,l])=>(
            <button key={l} className="iconbtn" style={{ color:'#fff', fontSize:24, flexDirection:'column', gap:5, height:'auto', width:'auto' }}><span className="mi">{ic}</span><span style={{ font:'500 10px/1 var(--font)', color:'rgba(255,255,255,0.7)' }}>{l}</span></button>
          ))}
        </div>
        <div style={{ display:'flex', gap:4, overflowX:'auto', padding:'0 calc(50% - 20px)', alignItems:'center' }}>
          {PHOTOS.map((s,i)=>(
            <div key={i} onClick={()=>setCur(i)} style={{ flex:'0 0 auto', width:i===cur?54:40, height:i===cur?54:40, borderRadius:i===cur?9:7, overflow:'hidden', opacity:i===cur?1:.55, outline:i===cur?'2px solid var(--accent)':'none', outlineOffset:1, cursor:'pointer' }}><img src={s} style={{ width:'100%', height:'100%', objectFit:'cover' }} /></div>
          ))}
        </div>
      </div>
    </PhoneShell>
  );
}

function Settings({ tab, setTab, accent, setAccent }) {
  const ACCENTS = ['brass','jade','clay','slate','plum','rust'];
  const HEX = { brass:'#C2A15A', jade:'#5BA086', clay:'#C2734C', slate:'#6E8FBE', plum:'#A06E92', rust:'#C25C44' };
  return (
    <PhoneShell>
      <AppBar large title="Settings" />
      <div className="screen-body" style={{ paddingBottom:24 }}>
        <div className="hpad"><div className="card" style={{ padding:16, display:'flex', alignItems:'center', gap:14 }}>
          <span className="row-thumb accent" style={{ width:48, height:48, borderRadius:999, fontSize:20 }}>M</span>
          <div style={{ flex:1 }}><div style={{ font:'600 16px/1.2 var(--font)' }}>Maya Okonkwo</div><div style={{ color:'var(--fg-muted)', fontSize:13, marginTop:3 }}>maya@protonmail.com</div></div>
          <Pill accent>Free</Pill>
        </div></div>
        <div className="sec-label t-overline" style={{ padding:'22px 20px 9px' }}>Vault</div>
        <div className="hpad"><div className="group">
          <Row title="Active shares" meta="3" />
          <Row title="Recovery phrase" />
          <Row title="Unlock with biometrics" trailing={<label className="switch"><input type="checkbox" defaultChecked /><span className="track"></span><span className="knob"></span></label>} />
        </div></div>
        <div className="sec-label t-overline" style={{ padding:'22px 20px 9px' }}>Appearance · Accent</div>
        <div className="hpad"><div className="group"><div style={{ display:'flex', gap:12, padding:16 }}>
          {ACCENTS.map(a=>(
            <span key={a} onClick={()=>setAccent(a)} style={{ width:30, height:30, borderRadius:999, cursor:'pointer', background:HEX[a], position:'relative', outline:accent===a?'2px solid var(--fg)':'none', outlineOffset:3 }}></span>
          ))}
        </div></div></div>
      </div>
      <TabBar active={tab} onChange={setTab} tabs={[
        { id:'vault', icon:'encrypted', label:'Vault' },
        { id:'activity', icon:'history', label:'Activity' },
        { id:'settings', icon:'settings', label:'Settings' },
      ]} />
    </PhoneShell>
  );
}

function UploadSheet({ onClose }) {
  const rows = [
    ['photo_library','var(--accent-soft)','var(--accent)','Photos & Videos','From your camera roll'],
    ['description','rgba(92,140,255,0.14)','#5C8CFF','Documents','PDF, DOCX, XLSX, slides'],
    ['music_note','rgba(47,191,143,0.14)','var(--success)','Audio','Tracks, voice memos'],
    ['folder_zip','rgba(255,178,62,0.14)','var(--warning)','Other File','zip, ipynb, py, anything.'],
  ];
  return (
    <Sheet onClose={onClose} title="Add to vault" sub="Files are encrypted on this device before upload.">
      {rows.map((r,i)=>(
        <div key={i} className="row" style={{ padding:'13px 4px' }} onClick={onClose}>
          <div className="row-thumb" style={{ background:r[1], color:r[2] }}><span className="mi">{r[0]}</span></div>
          <div className="row-main"><div className="row-title">{r[3]}</div><div className="row-sub">{r[4]}</div></div>
          <span className="mi row-chevron">chevron_right</span>
        </div>
      ))}
      <div className="sheet-actions"><Btn variant="secondary" block onClick={onClose}>Cancel</Btn></div>
    </Sheet>
  );
}

function App() {
  const [unlocked, setUnlocked] = useState(false);
  const [tab, setTab] = useState('vault');
  const [screen, setScreen] = useState('home'); // home | gallery | viewer
  const [viewerIdx, setViewerIdx] = useState(0);
  const [upload, setUpload] = useState(false);
  const [accent, setAccent] = useState('brass');

  useEffect(()=>{ document.documentElement.dataset.accent = accent; }, [accent]);

  if (!unlocked) return <Lock onUnlock={()=>setUnlocked(true)} />;

  let body;
  if (tab === 'settings') {
    body = <Settings tab={tab} setTab={(t)=>{ setTab(t); setScreen('home'); }} accent={accent} setAccent={setAccent} />;
  } else if (screen === 'gallery') {
    body = <Gallery onBack={()=>setScreen('home')} onOpen={(i)=>{ setViewerIdx(i); setScreen('viewer'); }} tab="pictures" setTab={()=>{}} />;
  } else if (screen === 'viewer') {
    body = <Viewer idx={viewerIdx} onBack={()=>setScreen('gallery')} />;
  } else {
    body = <Home tab={tab} setTab={(t)=>{ setTab(t); }} onOpenPhotos={()=>setScreen('gallery')} onUpload={()=>setUpload(true)} uploadOpen={upload} onCloseUpload={()=>setUpload(false)} />;
  }

  return body;
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
