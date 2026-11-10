// test-odasi-sink: izole agdaki tek "dis dunya". DNS (udp/53) ve HTTP/HTTPS (tcp/80,443)
// denemelerini kaydeder, hicbir yere iletmez. Kendi IP'sini her soruya cevap olarak verir.
const dgram = require('dgram');
const net = require('net');
const os = require('os');

const ip = Object.values(os.networkInterfaces()).flat()
  .find((i) => i && i.family === 'IPv4' && !i.internal).address;
const saat = () => new Date().toISOString().slice(11, 19);
const yaz = (s) => console.log(`${saat()} ${s}`);

function soruAdi(buf) {
  const parca = [];
  let i = 12;
  while (buf[i] !== 0 && i < buf.length) { parca.push(buf.slice(i + 1, i + 1 + buf[i]).toString()); i += buf[i] + 1; }
  return { ad: parca.join('.'), son: i + 5, tip: buf.readUInt16BE(i + 1) };
}

const dns = dgram.createSocket('udp4');
dns.on('message', (msg, rinfo) => {
  const { ad, son, tip } = soruAdi(msg);
  const a = tip === 1;
  if (a) yaz(`DNS   soruldu: ${ad.padEnd(26)} -> sadece sink cevapladı, dışarı gitmedi`);
  const bas = Buffer.from(msg.slice(0, son));
  bas.writeUInt16BE(0x8180, 2); bas.writeUInt16BE(a ? 1 : 0, 6); bas.writeUInt32BE(0, 8);
  const cevap = a ? Buffer.concat([bas, Buffer.from([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 5, 0, 4, ...ip.split('.').map(Number)])]) : bas;
  dns.send(cevap, rinfo.port, rinfo.address);
});
dns.bind(53, () => yaz(`sink hazır (${ip}): odanın tek "dış dünyası", hiçbir şeyi iletmez`));

function sni(buf) {
  try {
    let i = 43; i += 1 + buf[i]; i += 2 + buf.readUInt16BE(i); i += 1 + buf[i];
    const bitis = i + 2 + buf.readUInt16BE(i); i += 2;
    while (i < bitis) {
      const tip = buf.readUInt16BE(i); const uz = buf.readUInt16BE(i + 2);
      if (tip === 0) return buf.slice(i + 9, i + 4 + uz).toString();
      i += 4 + uz;
    }
  } catch { /* bozuk ClientHello */ }
  return '?';
}

[80, 443].forEach((port) => net.createServer((s) => {
  s.once('data', (d) => {
    const hedef = port === 443 ? sni(d) : (d.toString().match(/Host: *(\S+)/i) || [, '?'])[1];
    yaz(`${port === 443 ? 'HTTPS' : 'HTTP '} bağlantı: ${`${hedef}:${port}`.padEnd(26)} -> ENGELLENDİ, veri iletilmedi`);
    s.destroy();
  });
  s.on('error', () => {});
}).listen(port));
