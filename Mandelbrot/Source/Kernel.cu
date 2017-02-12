#include "Cuda.hpp"

#if _DEBUG
#   define cudaCall(cuda_func, ...) { cudaError_t status = cuda_func(__VA_ARGS__); cudaAssert((status), __FILE__, #cuda_func, __LINE__); }
#else
#   define cudaCall(cuda_func, ...) { cudaError_t status = cuda_func(__VA_ARGS__); }
#endif

inline void cudaAssert(cudaError_t status, const char *file, const char* func, int line)
{
    if (status != cudaSuccess)
    {
        std::stringstream ss;
        ss << "Error: " << cudaGetErrorString(status) << std::endl;
        ss << "Func: " << func << std::endl;
        ss << "File: " << file << std::endl;
        ss << "Line: " << line << std::endl;

        throw std::runtime_error(ss.str());
    }
}

__constant__ Image::pixel_t pixel_colour[16] = 
{
    { 66,  30,  15 },{ 25,   7,  26 },{ 9,   1,  47 },{ 4,   4,  73 },
    { 0,   7, 100 },{ 12,  44, 138 },{ 24,  82, 177 },{ 57, 125, 209 },
    { 134, 181, 229 },{ 211, 236, 248 },{ 241, 233, 191 },{ 248, 201,  95 },
    { 255, 170,   0 },{ 204, 128,   0 },{ 153,  87,   0 },{ 106,  52,   3 }
};

__global__ void mandelbrot(Image::pixel_t* image, const int width, const int height, const double scale, const double cx, const double cy)
{
    const int i = threadIdx.x + blockIdx.x * blockDim.x;
    const int j = threadIdx.y + blockIdx.y * blockDim.y;

    if (i >= width || j >= height)
    {
        return;
    }

    const std::uint8_t max_iter = 255;
    const double y = (i - (width >> 1)) * scale + cy;
    const double x = (j - (height >> 1)) * scale + cx;

    double zx, zy, zx2, zy2;
    
    zx = hypot(x - 0.25, y);

    if (x < zx - 2.0 * zx * zx + 0.25 || (x + 1) * (x + 1) + y * y < 0.0625)
    {
        return;
    }

    std::uint8_t iter = 0;
    zx = zy = zx2 = zy2 = 0.0;

    do {
        zy = 2.0 * zx * zy + y;
        zx = zx2 - zy2 + x;
        zx2 = zx * zx;
        zy2 = zy * zy;
    } while (iter++ < max_iter && zx2 + zy2 < 4.0);

    if (iter > 0 && iter < max_iter)
    {
        const std::uint8_t colour_idx = iter % 16;

        image[i * width + j] = pixel_colour[colour_idx];
    }
}

namespace cuda
{
    template<class T, typename... A>
    float launch_kernel(T kernel, dim3 work, A&&... args)
    {
        cudaEvent_t start;
        cudaCall(cudaEventCreate, &start);

        cudaEvent_t stop;
        cudaCall(cudaEventCreate, &stop);

        int blockSize, minGridSize;
        cudaOccupancyMaxPotentialBlockSize(&minGridSize, &blockSize, mandelbrot, 0, 0);
        blockSize = (int)pow(2, floor(log(sqrt(blockSize)) / log(2)));

        dim3 block(blockSize, blockSize);
        dim3 grid((work.x + block.x - 1) / block.x, (work.y + block.y - 1) / block.y);
        grid.x = grid.x > minGridSize ? grid.x : minGridSize;
        grid.y = grid.y > minGridSize ? grid.y : minGridSize;

        cudaCall(cudaEventRecord, start, 0);

        kernel << < grid, block >> >(std::forward<A>(args)...);

        cudaCall(cudaGetLastError);
        cudaCall(cudaEventRecord, stop, 0);
        cudaCall(cudaEventSynchronize, stop);

        float elapsed_time;
        cudaCall(cudaEventElapsedTime, &elapsed_time, start, stop);

        cudaCall(cudaEventDestroy, start);
        cudaCall(cudaEventDestroy, stop);

        return elapsed_time;
    }

    std::uint64_t generate_mandelbrot(Image& image, double cx, double cy)
    {
        Image::pixel_t* d_img_data;
        const int img_size = image.width * image.height * sizeof(Image::pixel_t);
        const double scale = 1.0 / (image.width / 4.0);

        cudaCall(cudaMalloc, (void**)&d_img_data, img_size);
        cudaCall(cudaMemset, d_img_data, 0, img_size);

        float elapsed_time = launch_kernel(mandelbrot, dim3(image.width, image.height), d_img_data, image.width, image.height, scale, cx, cy);

        cudaCall(cudaMemcpy, &image.data[0], d_img_data, img_size, cudaMemcpyDeviceToHost);

        cudaCall(cudaFree, d_img_data);

        return static_cast<std::uint64_t>(elapsed_time);
    }
}