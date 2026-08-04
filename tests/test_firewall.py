r"""
Cosa dice l'app quando non trova nessuno.

Non e' un test di rete: e' un test di **onesta'**. La riga «Nessun dispositivo»
che c'era prima copriva cause opposte — il firewall, un router che isola i
dispositivi, l'altro col vault bloccato, un permesso mancante nell'APK — e il
04/08/2026 e' costata una serata di collaudo a chi il codice ce l'aveva sotto
mano. Qui si pretende che quello che l'app SA resti separato da quello che
puo' solo suggerire di guardare.

La parte che alza l'UAC non si prova: aprirebbe una finestra di Windows in
mezzo alla suite.

    tests\run.ps1
"""

from __future__ import annotations
import os
import sys
import unittest

_QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(_QUI), "VaultMind_Windows"))

from app import firewall  # noqa: E402


class TestDiagnosi(unittest.TestCase):

    def diagnosi(self, **kw):
        base = dict(acceso=True, in_ascolto=True, abbinati=1,
                    porta_sync=8732, porta_scoperta=8733)
        base.update(kw)
        return firewall.diagnosi(**base)

    def test_col_sync_spento_lo_dice_e_basta(self):
        """Il sync spento e' LA causa: elencare anche il resto manderebbe a
        controllare il router per una casella non spuntata."""
        d = self.diagnosi(acceso=False, in_ascolto=False, abbinati=0)
        self.assertEqual(1, len(d["certi"]))
        self.assertIn("spento", d["certi"][0])

    def test_nessuno_abbinato_e_una_certezza_non_un_sospetto(self):
        d = self.diagnosi(abbinati=0)
        self.assertTrue(any("abbinato" in m for m in d["certi"]))

    def test_la_porta_occupata_si_distingue_dal_firewall(self):
        """Sono due guasti diversi e due rimedi diversi: uno e' un altro
        programma sulla 8732, l'altro e' Windows che blocca."""
        d = self.diagnosi(in_ascolto=False)
        self.assertTrue(any("8732" in m for m in d["certi"]))

    def test_quando_va_tutto_bene_non_si_inventa_una_causa(self):
        """Il caso vero di una rete che isola i dispositivi: l'app non ha modo
        di saperlo, e dire una causa a caso e' peggio che dire «guarda qui»."""
        d = self.diagnosi()
        self.assertEqual([], d["certi"])
        self.assertTrue(d["da_provare"], "senza suggerimenti si torna alla riga muta")

    def test_i_sospetti_ci_sono_sempre_e_i_certi_no(self):
        for acceso in (True, False):
            with self.subTest(acceso=acceso):
                self.assertTrue(self.diagnosi(acceso=acceso)["da_provare"])

    def test_dice_dove_guardare_sulla_rete(self):
        """L'indirizzo e la porta servono a chi il problema lo sa affrontare:
        senza, l'unica strada e' credere all'app sulla parola."""
        d = self.diagnosi()
        self.assertEqual(8732, d["porta_sync"])
        self.assertEqual(8733, d["porta_scoperta"])
        self.assertIn("programma", d)


class TestComando(unittest.TestCase):
    """Il comando passato a netsh. Sbagliarlo si vedrebbe solo su un computer
    con un firewall che blocca davvero, cioe' mai qui."""

    def test_cancella_prima_di_riscrivere(self):
        """In Windows un divieto batte un permesso: chi ha chiuso l'avviso di
        Windows ha una regola di BLOCCO, e aggiungerne una di permesso
        lascerebbe vincere quella. Il pulsante sembrerebbe non fare niente."""
        c = firewall._comando(r"C:\x\VaultMind.exe", 8732, 8733)
        self.assertLess(c.index("delete rule"), c.index("add rule"))

    def test_apre_tutte_e_due_le_porte_e_solo_in_ingresso(self):
        c = firewall._comando(r"C:\x\VaultMind.exe", 8732, 8733)
        self.assertIn("protocol=TCP localport=8732", c)
        self.assertIn("protocol=UDP localport=8733", c)
        self.assertNotIn("dir=out", c)

    def test_il_percorso_con_spazi_resta_fra_virgolette(self):
        """Il caso normale, non un limite: l'app sta in «Program Files» o in un
        profilo utente con nome e cognome."""
        exe = r"C:\Users\Nome Cognome\Programs\VaultMind\VaultMind.exe"
        c = firewall._comando(exe, 8732, 8733)
        self.assertIn(f'program="{exe}"', c)

    def test_la_regola_non_e_limitata_al_profilo_privato(self):
        """Sembrerebbe piu' elegante e sarebbe sbagliato: la rete di casa viene
        classificata Pubblica molto spesso — succede sulla macchina di sviluppo
        di questo progetto. Una regola che non si applica e' peggio di nessuna
        regola, perche' sembra fatta."""
        c = firewall._comando(r"C:\x\VaultMind.exe", 8732, 8733)
        self.assertNotIn("profile=private", c)


if __name__ == "__main__":
    unittest.main(verbosity=2)
