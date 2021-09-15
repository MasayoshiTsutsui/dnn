#include <mma.h>
#include <cuda_fp16.h>
#include <iostream>

#define WARPSIZE 32
#define TILESIZE 16
#define ELEMS_TILE 256
#define TILEDIM_BLOCK 2 //1blockあたり、16*16の小行列タイルを2*2個生成する
#define TILES_BLOCK 4
using namespace std;
using namespace nvcuda;

//128スレッド4warpで起動されることを想定。2*2のタイルを1blockで計算
//タイルできれいに分割できない行列は未対応
__global__
void dot_TensorCore(float *a, float *b, float *c, int32_t m, int32_t n, int32_t k) {

	__shared__ __half a_half[ELEMS_TILE*TILES_BLOCK] __align__(32);
	__shared__ __half b_half[ELEMS_TILE*TILES_BLOCK] __align__(32);
	__shared__ __half c_half[ELEMS_TILE*TILES_BLOCK] __align__(32);

	int32_t lid = threadIdx.x % WARPSIZE;
	int32_t lid_hex = lid % 16;
	int32_t hexid = lid / 16;
	int32_t wid = threadIdx.x / WARPSIZE;
	int32_t tileIdx_x = blockIdx.x * TILEDIM_BLOCK + wid % 2; // 自スレッドがcのx軸方向何枚目のタイル生成担当か
	int32_t tileIdx_y = blockIdx.y * TILEDIM_BLOCK + wid / 2; // 自スレッドがcのy軸以下略

	wmma::fragment<wmma::matrix_a, TILESIZE, TILESIZE, TILESIZE, __half, wmma::row_major> a_frag;
	wmma::fragment<wmma::matrix_b, TILESIZE, TILESIZE, TILESIZE, __half, wmma::row_major> b_frag;
	wmma::fragment<wmma::accumulator, TILESIZE, TILESIZE, TILESIZE, __half> c_frag;

	wmma::fill_fragment(c_frag, __float2half(0.f));
	for (int32_t i=0; i < k / TILESIZE; i++) {
		//a,bの中でのタイルの先頭要素のidx
		int32_t a_offsetbase = tileIdx_y * TILESIZE * k + i * TILESIZE;
		//16*16*16でやろうとしてるので、tidが0~15の担当要素、16~31の担当要素は隔たりがある
		//1回で小行列の2行分をa_halfに。
		a_half[wid*ELEMS_TILE + lid] = __float2half(a[a_offsetbase + hexid*k+lid_hex]);
		a_offsetbase += 2 * k; //2行下に移動
		a_half[wid*ELEMS_TILE + lid+32] = __float2half(a[a_offsetbase + hexid*k+lid_hex]);
		a_offsetbase += 2 * k;
		a_half[wid*ELEMS_TILE + lid+64] = __float2half(a[a_offsetbase + hexid*k+lid_hex]);
		a_offsetbase += 2 * k;
		a_half[wid*ELEMS_TILE + lid+96] = __float2half(a[a_offsetbase + hexid*k+lid_hex]);
		a_offsetbase += 2 * k;
		a_half[wid*ELEMS_TILE + lid+128] = __float2half(a[a_offsetbase + hexid*k+lid_hex]);
		a_offsetbase += 2 * k;
		a_half[wid*ELEMS_TILE + lid+160] = __float2half(a[a_offsetbase + hexid*k+lid_hex]);
		a_offsetbase += 2 * k;
		a_half[wid*ELEMS_TILE + lid+192] = __float2half(a[a_offsetbase + hexid*k+lid_hex]);
		a_offsetbase += 2 * k;
		a_half[wid*ELEMS_TILE + lid+224] = __float2half(a[a_offsetbase + hexid*k+lid_hex]);

		int32_t b_offsetbase = i * TILESIZE * n + tileIdx_x * TILESIZE;
		b_half[wid*ELEMS_TILE + lid] = __float2half(b[b_offsetbase + hexid*n+lid_hex]);
		b_offsetbase += 2 * n;
		b_half[wid*ELEMS_TILE + lid+32] = __float2half(b[b_offsetbase + hexid*n+lid_hex]);
		b_offsetbase += 2 * n;
		b_half[wid*ELEMS_TILE + lid+64] = __float2half(b[b_offsetbase + hexid*n+lid_hex]);
		b_offsetbase += 2 * n;
		b_half[wid*ELEMS_TILE + lid+96] = __float2half(b[b_offsetbase + hexid*n+lid_hex]);
		b_offsetbase += 2 * n;
		b_half[wid*ELEMS_TILE + lid+128] = __float2half(b[b_offsetbase + hexid*n+lid_hex]);
		b_offsetbase += 2 * n;
		b_half[wid*ELEMS_TILE + lid+160] = __float2half(b[b_offsetbase + hexid*n+lid_hex]);
		b_offsetbase += 2 * n;
		b_half[wid*ELEMS_TILE + lid+192] = __float2half(b[b_offsetbase + hexid*n+lid_hex]);
		b_offsetbase += 2 * n;
		b_half[wid*ELEMS_TILE + lid+224] = __float2half(b[b_offsetbase + hexid*n+lid_hex]);
		wmma::load_matrix_sync(a_frag, &a_half[wid*ELEMS_TILE], 16);
		wmma::load_matrix_sync(b_frag, &b_half[wid*ELEMS_TILE], 16);
		wmma::mma_sync(c_frag, a_frag, b_frag, c_frag);
	}

	wmma::store_matrix_sync(&c_half[wid*ELEMS_TILE], c_frag, 16, wmma::mem_row_major);
	int32_t c_offsetbase = tileIdx_y * TILESIZE * n + tileIdx_x * TILESIZE;
	c[c_offsetbase + hexid*n+lid_hex] = __half2float(c_half[wid*ELEMS_TILE + lid]);
	c_offsetbase += 2 * n;
	c[c_offsetbase + hexid*n+lid_hex] = __half2float(c_half[wid*ELEMS_TILE + lid+32]);
	c_offsetbase += 2 * n;
	c[c_offsetbase + hexid*n+lid_hex] = __half2float(c_half[wid*ELEMS_TILE + lid+64]);
	c_offsetbase += 2 * n;
	c[c_offsetbase + hexid*n+lid_hex] = __half2float(c_half[wid*ELEMS_TILE + lid+96]);
	c_offsetbase += 2 * n;
	c[c_offsetbase + hexid*n+lid_hex] = __half2float(c_half[wid*ELEMS_TILE + lid+128]);
	c_offsetbase += 2 * n;
	c[c_offsetbase + hexid*n+lid_hex] = __half2float(c_half[wid*ELEMS_TILE + lid+160]);
	c_offsetbase += 2 * n;
	c[c_offsetbase + hexid*n+lid_hex] = __half2float(c_half[wid*ELEMS_TILE + lid+192]);
	c_offsetbase += 2 * n;
	c[c_offsetbase + hexid*n+lid_hex] = __half2float(c_half[wid*ELEMS_TILE + lid+224]);
}

int main() {
	int32_t n = 32;
	int32_t matsize = n * n;
	float *a, *b, *c;
	float *a_dev, *b_dev, *c_dev;
	a = (float*)malloc(sizeof(float) * matsize);
	b = (float*)malloc(sizeof(float) * matsize);
	c = (float*)malloc(sizeof(float) * matsize);

	cudaMalloc((void**)&a_dev, sizeof(float) * matsize);
	cudaMalloc((void**)&b_dev, sizeof(float) * matsize);
	cudaMalloc((void**)&c_dev, sizeof(float) * matsize);
	for (int32_t i=0; i < matsize; i++) {
		a[i] = 1.;
		b[i] = 1.;
		c[i] = 0.;
	}
	//for (int32_t i=0; i < n; i++) {
		//b[i] = 1.;
	//}
	cudaMemcpy(a_dev, a, sizeof(float)*matsize, cudaMemcpyHostToDevice);
	cudaMemcpy(b_dev, b, sizeof(float)*matsize, cudaMemcpyHostToDevice);
	dot_TensorCore<<<1, 128>>>(a_dev,  b_dev, c_dev, n, n, n);
	cudaMemcpy(c, c_dev, sizeof(float)*matsize, cudaMemcpyDeviceToHost);
	for (int32_t i=0; i < n; i++) {
		for (int32_t j=0; j < n; j++) {
			cout << c[i*n+j] << " ";
		}
		cout << endl;
	}
	return 0;
}
