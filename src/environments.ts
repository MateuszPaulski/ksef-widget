export type Environment = 'test' | 'demo' | 'prod';

export const ENVIRONMENTS: Record<Environment, { apiBase: string; qrBase: string }> = {
  test: { apiBase: 'https://api-test.ksef.mf.gov.pl/v2', qrBase: 'https://qr-test.ksef.mf.gov.pl' },
  demo: { apiBase: 'https://api-demo.ksef.mf.gov.pl/v2', qrBase: 'https://qr-demo.ksef.mf.gov.pl' },
  prod: { apiBase: 'https://api.ksef.mf.gov.pl/v2', qrBase: 'https://qr.ksef.mf.gov.pl' },
};
