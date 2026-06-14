// CipherNest UI Kit — Primitives
// Reusable, mostly-cosmetic React components built on app.css.
// Exported to window for cross-file use.
const { useState } = React;

// Status bar
function StatusBar() {
  return (
    <div className="statusbar">
      <span>9:41</span>
      <span className="sb-right"><span className="mi">signal_cellular_alt</span><span className="mi">wifi</span><span className="mi">battery_full</span></span>
    </div>
  );
}

// Phone shell — fixed 412×915, holds a screen
function PhoneShell({ children, black }) {
  return (
    <div className="phone" style={black ? { background: '#000' } : null}>
      <StatusBar />
      {children}
    </div>
  );
}

function IconBtn({ icon, onClick, color, size, fill }) {
  return (
    <button className="iconbtn" onClick={onClick} style={{ color: color || 'var(--fg)' }}>
      <span className={'mi' + (fill ? ' fill' : '')} style={size ? { fontSize: size } : null}>{icon}</span>
    </button>
  );
}

// Top app bar
function AppBar({ title, onBack, trailing, large }) {
  if (large) {
    return (
      <div className="appbar large" style={{ display:'flex', alignItems:'center', justifyContent:'space-between', paddingTop:10 }}>
        <div style={{ font:'700 30px/1.1 var(--font)', letterSpacing:'-0.022em' }}>{title}</div>
        <div className="appbar-trailing">{trailing}</div>
      </div>
    );
  }
  return (
    <div className="appbar" style={{ paddingRight: 8 }}>
      {onBack && <IconBtn icon="arrow_back" onClick={onBack} />}
      <span className="appbar-title">{title}</span>
      <div className="appbar-trailing">{trailing}</div>
    </div>
  );
}

// Bottom tab bar
function TabBar({ tabs, active, onChange }) {
  return (
    <div className="tabbar">
      {tabs.map(t => (
        <div key={t.id} className={'tab' + (active === t.id ? ' active' : '')} onClick={() => onChange(t.id)}>
          <span className={'mi' + (active === t.id ? ' fill' : '')}>{t.icon}</span>{t.label}
        </div>
      ))}
    </div>
  );
}

// Generic list row
function Row({ thumb, thumbAccent, title, sub, meta, trailing, onClick }) {
  return (
    <div className="row" onClick={onClick}>
      {thumb && <div className={'row-thumb' + (thumbAccent ? ' accent' : '')}><i className={thumb}></i></div>}
      <div className="row-main"><div className="row-title">{title}</div>{sub && <div className="row-sub">{sub}</div>}</div>
      {meta && <div className="row-meta">{meta}</div>}
      {trailing || <span className="mi row-chevron">chevron_right</span>}
    </div>
  );
}

// Pill
function Pill({ children, accent, solid }) {
  return <span className={'pill' + (accent ? ' accent' : '') + (solid ? ' solid' : '')}>{children}</span>;
}

// Button
function Btn({ children, variant, block, lg, onClick }) {
  const cls = 'btn btn-' + (variant || 'primary') + (block ? ' btn-block' : '') + (lg ? ' btn-lg' : '');
  return <button className={cls} onClick={onClick}>{children}</button>;
}

// Bottom sheet
function Sheet({ children, onClose, title, sub }) {
  return (
    <div className="sheet-scrim" onClick={onClose}>
      <div className="sheet" onClick={e => e.stopPropagation()}>
        <div className="sheet-handle"></div>
        {title && <div className="sheet-title">{title}</div>}
        {sub && <div className="sheet-sub">{sub}</div>}
        {children}
      </div>
    </div>
  );
}

// Category vault card
function VaultCard({ icon, tint, color, title, sub, thumbs, onClick }) {
  return (
    <div className="card" style={{ overflow:'hidden' }} onClick={onClick}>
      <div className="vcard">
        <div className="vcard-ic" style={{ background: tint, color }}><span className="mi">{icon}</span></div>
        <div className="vcard-main"><div className="vcard-t">{title}</div><div className="vcard-s">{sub}</div></div>
        {thumbs
          ? <div className="minithumbs">{thumbs.map((s,i)=><img key={i} src={s} />)}</div>
          : <span className="mi row-chevron">chevron_right</span>}
      </div>
    </div>
  );
}

Object.assign(window, { StatusBar, PhoneShell, IconBtn, AppBar, TabBar, Row, Pill, Btn, Sheet, VaultCard });
