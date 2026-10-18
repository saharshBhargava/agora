import { Suspense } from 'react';
import JoinScreen from './JoinScreen';

export default function JoinPage() {
  return (
    <Suspense fallback={null}>
      <JoinScreen />
    </Suspense>
  );
}
