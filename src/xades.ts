import { createHash, sign, verify, type BinaryLike, type KeyObject } from 'node:crypto';
import { SignedXml, type SignatureAlgorithm } from 'xml-crypto';
import type { Credentials } from './credentials.ts';

const ECDSA_SHA256 = 'http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256';
const RSA_SHA256 = 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256';
const EXC_C14N = 'http://www.w3.org/2001/10/xml-exc-c14n#';
const ENVELOPED = 'http://www.w3.org/2000/09/xmldsig#enveloped-signature';
const SHA256 = 'http://www.w3.org/2001/04/xmlenc#sha256';

/** ECDSA with SHA-256; SignatureValue is raw R || S (IEEE P1363), as KSeF requires. */
export class EcdsaSha256 implements SignatureAlgorithm {
  getSignature(signedInfo: BinaryLike, privateKey: KeyObject): string {
    return sign('sha256', Buffer.from(signedInfo as string), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString(
      'base64',
    );
  }

  verifySignature(material: string, key: string | Buffer, signatureValue: string): boolean {
    return verify(
      'sha256',
      Buffer.from(material),
      { key, dsaEncoding: 'ieee-p1363' },
      Buffer.from(signatureValue, 'base64'),
    );
  }

  getAlgorithmName(): string {
    return ECDSA_SHA256;
  }
}

export function buildAuthTokenRequest(challenge: string, nip: string): string {
  return `<?xml version="1.0" encoding="utf-8"?><AuthTokenRequest xmlns="http://ksef.mf.gov.pl/auth/token/2.0"><Challenge>${challenge}</Challenge><ContextIdentifier><Nip>${nip}</Nip></ContextIdentifier><SubjectIdentifierType>certificateSubject</SubjectIdentifierType></AuthTokenRequest>`;
}

function escapeXml(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function buildQualifyingProperties(credentials: Credentials, signingTime: Date): string {
  const { certificate } = credentials;
  const signedAt = new Date(signingTime.getTime() - 60_000).toISOString();
  const certDigest = createHash('sha256').update(certificate.raw).digest('base64');
  const issuer = escapeXml(certificate.issuer.split('\n').reverse().join(', '));
  const serial = BigInt(`0x${certificate.serialNumber}`).toString();
  return `<xades:QualifyingProperties xmlns:xades="http://uri.etsi.org/01903/v1.3.2#" Target="#Signature"><xades:SignedProperties Id="SignedProperties"><xades:SignedSignatureProperties><xades:SigningTime>${signedAt}</xades:SigningTime><xades:SigningCertificate><xades:Cert><xades:CertDigest><ds:DigestMethod Algorithm="${SHA256}"/><ds:DigestValue>${certDigest}</ds:DigestValue></xades:CertDigest><xades:IssuerSerial><ds:X509IssuerName>${issuer}</ds:X509IssuerName><ds:X509SerialNumber>${serial}</ds:X509SerialNumber></xades:IssuerSerial></xades:Cert></xades:SigningCertificate></xades:SignedSignatureProperties></xades:SignedProperties></xades:QualifyingProperties>`;
}

/** Enveloped XAdES-BES signature, laid out like the official KSeF C# client's SignatureService. */
export function signXades(xml: string, credentials: Credentials, signingTime: Date): string {
  const isEc = credentials.privateKey.asymmetricKeyType === 'ec';
  const sig = new SignedXml({
    privateKey: credentials.privateKey,
    publicCert: credentials.certificatePem,
    signatureAlgorithm: isEc ? ECDSA_SHA256 : RSA_SHA256,
    canonicalizationAlgorithm: EXC_C14N,
    objects: [{ content: buildQualifyingProperties(credentials, signingTime) }],
  });
  if (isEc) {
    sig.SignatureAlgorithms[ECDSA_SHA256] = EcdsaSha256;
  }
  sig.addReference({
    xpath: '/*',
    isEmptyUri: true,
    transforms: [ENVELOPED, EXC_C14N],
    digestAlgorithm: SHA256,
  });
  sig.addReference({
    xpath: "//*[@Id='SignedProperties']",
    type: 'http://uri.etsi.org/01903#SignedProperties',
    transforms: [EXC_C14N],
    digestAlgorithm: SHA256,
  });
  sig.computeSignature(xml, {
    prefix: 'ds',
    attrs: { Id: 'Signature' },
    location: { reference: '/*', action: 'append' },
  });
  return sig.getSignedXml();
}
