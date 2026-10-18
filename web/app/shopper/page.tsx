import { Suspense } from 'react';
import ShopperScreen from './ShopperScreen';

export default function ShopperPage() {
  return (
    <Suspense fallback={null}>
      <ShopperScreen />
    </Suspense>
  );
}
