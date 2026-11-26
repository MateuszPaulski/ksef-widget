import { randomInt } from 'node:crypto';

const WEIGHTS = [6, 5, 7, 2, 3, 4, 5, 6, 7];

/** Random NIP matching the KSeF pattern ^[1-9]((\d[1-9])|([1-9]\d))\d{7}$ with a valid checksum. */
export function randomNip(): string {
  for (;;) {
    const digits = Array.from({ length: 9 }, () => randomInt(0, 10));
    digits[0] = randomInt(1, 10);
    if (digits[1] === 0 && digits[2] === 0) continue;
    const sum = digits.reduce((acc, digit, i) => acc + digit * WEIGHTS[i]!, 0);
    const check = sum % 11;
    if (check === 10) continue;
    return [...digits, check].join('');
  }
}
