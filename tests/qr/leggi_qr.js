// Decodifica con jsQR (web/jsQR.js, lo stesso lettore dell'app) le matrici QR
// prodotte da app/qr.py. Le legge da stdin come JSON: [[0,1,...],...] per
// ciascun QR, e scrive su stdout un JSON con il testo letto (o null).
//
// Lo usa tests/test_qr.py: un QR non si giudica guardandolo, lo si fa leggere
// a un programma scritto da altri.
const path = require("path");
const jsQR = require(path.join(__dirname, "..", "..", "VaultMind_Windows", "app", "web", "jsQR.js"));

let ingresso = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => (ingresso += d));
process.stdin.on("end", () => {
  const matrici = JSON.parse(ingresso);
  const letti = matrici.map((m) => {
    const scala = 6, margine = 4;
    const lato = (m.length + 2 * margine) * scala;
    const px = new Uint8ClampedArray(lato * lato * 4).fill(255);
    for (let y = 0; y < m.length; y++)
      for (let x = 0; x < m.length; x++)
        if (m[y][x])
          for (let dy = 0; dy < scala; dy++)
            for (let dx = 0; dx < scala; dx++) {
              const i = (((y + margine) * scala + dy) * lato + (x + margine) * scala + dx) * 4;
              px[i] = px[i + 1] = px[i + 2] = 0;
            }
    const r = jsQR(px, lato, lato, { inversionAttempts: "dontInvert" });
    return r ? r.data : null;
  });
  process.stdout.write(JSON.stringify(letti));
});
