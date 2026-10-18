import { Suspense } from 'react';
import SettleScreen from './SettleScreen';

export default function SettlePage() {
  return (
    <Suspense fallback={null}>
      <SettleScreen />
    </Suspense>
  );
}
