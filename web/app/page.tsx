import { Suspense } from 'react';
import StartScreen from './StartScreen';

export default function Home() {
  return (
    <Suspense fallback={null}>
      <StartScreen />
    </Suspense>
  );
}
