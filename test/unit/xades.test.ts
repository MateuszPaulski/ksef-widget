import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { SignedXml } from 'xml-crypto';
import { loadCredentials, type Credentials } from '../../src/credentials.ts';
import { EcdsaSha256, buildAuthTokenRequest, signXades } from '../../src/xades.ts';
import { makeTestCredentials } from '../support/certs.ts';
import { randomNip } from '../support/nip.ts';

const DS = 'http://www.w3.org/2000/09/xmldsig#';
const EXC_C14N = 'http://www.w3.org/2001/10/xml-exc-c14n#';
const SHA256 = 'http://www.w3.org/2001/04/xmlenc#sha256';
const ENVELOPED = `${DS}enveloped-signature`;
const ECDSA_SHA256 = 'http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256';
const RSA_SHA256 = 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256';

function escapeXml(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/** Text content of the first element with the given qualified name. */
function textOf(xml: string, name: string): string | undefined {
  return xml.match(new RegExp(`<${name}(?: [^>]*)?>([^<]*)</${name}>`))?.[1];
}

describe('buildAuthTokenRequest', () => {
  it('builds the AuthTokenRequest document', () => {
    assert.equal(
      buildAuthTokenRequest('20261126-CR-0123456789-ABCDEF0123-AB', '5265877635'),
      '<?xml version="1.0" encoding="utf-8"?><AuthTokenRequest xmlns="http://ksef.mf.gov.pl/auth/token/2.0"><Challenge>20261126-CR-0123456789-ABCDEF0123-AB</Challenge><ContextIdentifier><Nip>5265877635</Nip></ContextIdentifier><SubjectIdentifierType>certificateSubject</SubjectIdentifierType></AuthTokenRequest>',
    );
  });
});

describe('signXades', () => {
  let dir: string;
  const credentialsByType = {} as Record<'rsa' | 'ec', Credentials>;

  before(async () => {
    dir = await mkdtemp(join(tmpdir(), 'ksef-xades-'));
    for (const keyType of ['rsa', 'ec'] as const) {
      const files = await makeTestCredentials({ nip: randomNip(), keyType, dir });
      credentialsByType[keyType] = await loadCredentials(files.certificatePath, files.keyPath, files.password);
    }
  });

  after(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  for (const keyType of ['rsa', 'ec'] as const) {
    describe(keyType, () => {
      let credentials: Credentials;
      let signed: string;
      let signature: string;

      before(() => {
        credentials = credentialsByType[keyType];
        signed = signXades(
          buildAuthTokenRequest('20261126-CR-0123456789-ABCDEF0123-AB', '5265877635'),
          credentials,
          new Date('2026-11-26T08:00:00Z'),
        );
        signature = signed.match(/<ds:Signature[\s\S]*<\/ds:Signature>/)![0];
      });

      it('uses the expected signature and canonicalization methods', () => {
        const method = keyType === 'rsa' ? RSA_SHA256 : ECDSA_SHA256;
        assert.match(signature, new RegExp(`<ds:SignatureMethod Algorithm="${method}"`));
        assert.match(signature, new RegExp(`<ds:CanonicalizationMethod Algorithm="${EXC_C14N}"`));
      });

      it('has exactly the two XAdES references', () => {
        assert.equal(signature.match(/<ds:Reference[ >]/g)?.length, 2);
        const rootRef = new RegExp(
          `<ds:Reference URI=""><ds:Transforms><ds:Transform Algorithm="${ENVELOPED}"\\s*/><ds:Transform Algorithm="${EXC_C14N}"\\s*/></ds:Transforms><ds:DigestMethod Algorithm="${SHA256}"\\s*/>`,
        );
        assert.match(signature, rootRef);
        const propsRef = new RegExp(
          `<ds:Reference (?:URI="#SignedProperties" Type="http://uri.etsi.org/01903#SignedProperties"|Type="http://uri.etsi.org/01903#SignedProperties" URI="#SignedProperties")><ds:Transforms><ds:Transform Algorithm="${EXC_C14N}"\\s*/></ds:Transforms><ds:DigestMethod Algorithm="${SHA256}"\\s*/>`,
        );
        assert.match(signature, propsRef);
      });

      it('appends an Id="Signature" signature as the last child of the root', () => {
        assert.match(signature, /^<ds:Signature [^>]*Id="Signature"/);
        assert.ok(signed.endsWith('</ds:Signature></AuthTokenRequest>'));
      });

      it('carries QualifyingProperties targeting the signature inside ds:Object', () => {
        assert.match(
          signature,
          /<ds:Object><xades:QualifyingProperties [^>]*xmlns:xades="http:\/\/uri\.etsi\.org\/01903\/v1\.3\.2#"[^>]*>/,
        );
        assert.match(signature, /<xades:QualifyingProperties [^>]*Target="#Signature"/);
        assert.match(signature, /<xades:SignedProperties Id="SignedProperties">/);
      });

      it('signs one minute before the given time', () => {
        assert.equal(textOf(signature, 'xades:SigningTime'), '2026-11-26T07:59:00.000Z');
      });

      it('describes the signing certificate', () => {
        const { certificate } = credentials;
        const certDigest = signature.match(
          new RegExp(`<xades:CertDigest><ds:DigestMethod Algorithm="${SHA256}"\\s*/><ds:DigestValue>([^<]*)</ds:DigestValue></xades:CertDigest>`),
        )?.[1];
        assert.equal(certDigest, createHash('sha256').update(certificate.raw).digest('base64'));
        assert.equal(textOf(signature, 'ds:X509SerialNumber'), BigInt('0x' + certificate.serialNumber).toString());
        assert.equal(
          textOf(signature, 'ds:X509IssuerName'),
          escapeXml(certificate.issuer.split('\n').reverse().join(', ')),
        );
      });

      it('embeds the certificate in KeyInfo', () => {
        const body = credentials.certificatePem.replace(/-----(BEGIN|END) CERTIFICATE-----|\s/g, '');
        assert.equal(textOf(signature, 'ds:X509Certificate'), body);
      });

      if (keyType === 'ec') {
        it('writes SignatureValue as 64 raw bytes (R || S)', () => {
          const value = textOf(signature, 'ds:SignatureValue')!;
          assert.equal(Buffer.from(value, 'base64').length, 64);
        });
      }

      it('verifies against its own certificate', () => {
        const verifier = new SignedXml({ publicCert: credentials.certificatePem });
        verifier.SignatureAlgorithms[ECDSA_SHA256] = EcdsaSha256;
        verifier.loadSignature(signature);
        assert.equal(verifier.checkSignature(signed), true);
      });
    });
  }
});
