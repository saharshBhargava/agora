import { Suspense } from 'react';
import ClaimScreen from './ClaimScreen';

export default function ClaimPage() {
  return (
    <Suspense fallback={null}>
      <ClaimScreen />
    </Suspense>
  );
}
