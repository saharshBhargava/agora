const isDev = process.env.NODE_ENV !== 'production';

/** @type {import('next').NextConfig} */
const nextConfig = isDev
  ? {
      // Dev only: proxy the API to the Dibs server. Production is a static export served same-origin.
      async rewrites() {
        return [{ source: '/api/:path*', destination: 'http://localhost:3000/api/:path*' }];
      },
    }
  : { output: 'export' };

export default nextConfig;
