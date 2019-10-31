#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <getopt.h>
#include <stdlib.h>
#include <sys/time.h>
extern "C" { 
    #include "libs/bitmap.h"
}

// Divide the problem into blocks of BLOCKX x BLOCKY threads
#define BLOCKY 8
#define BLOCKX 8

#define ERROR_EXIT -1
#define cudaErrorCheck(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort = true)
{
    if (code != cudaSuccess)
    {
        fprintf(stderr, "GPUassert: %s %s %s %d\n", cudaGetErrorName(code), cudaGetErrorString(code), file, line);
        if (abort)
            exit(code);
    }
}

// Convolutional Filter Examples, each with dimension 3,
// gaussian filter with dimension 5
// If you apply another filter, remember not only to exchange
// the filter but also the filterFactor and the correct dimension.

/*
int const sobelYFilter[] = {-1, -2, -1,
                            0, 0, 0,
                            1, 2, 1};
float const sobelYFilterFactor = (float)1.0;

int const sobelXFilter[] = {-1, -0, -1,
                            -2, 0, -2,
                            -1, 0, -1, 0};
float const sobelXFilterFactor = (float)1.0;
*/

int const laplacian1Filter[] = {-1, -4, -1,
                                -4, 20, -4,
                                -1, -4, -1};

float const laplacian1FilterFactor = (float)1.0;

/*
int const laplacian2Filter[] = {0, 1, 0,
                                1, -4, 1,
                                0, 1, 0};
float const laplacian2FilterFactor = (float)1.0;

int const laplacian3Filter[] = {-1, -1, -1,
                                -1, 8, -1,
                                -1, -1, -1};
float const laplacian3FilterFactor = (float)1.0;

// Bonus Filter:
int const gaussianFilter[] = {1, 4, 6, 4, 1,
                              4, 16, 24, 16, 4,
                              6, 24, 36, 24, 6,
                              4, 16, 24, 16, 4,
                              1, 4, 6, 4, 1};
float const gaussianFilterFactor = (float)1.0 / 256.0;
*/

// CPU - Apply convolutional filter on image data
void applyFilter(unsigned char **out, unsigned char **in, unsigned int width, unsigned int height, int *filter, unsigned int filterDim, float filterFactor)
{
    unsigned int const filterCenter = (filterDim / 2);
    for (unsigned int y = 0; y < height; y++)
    {
        for (unsigned int x = 0; x < width; x++)
        {
            int aggregate = 0;
            for (unsigned int ky = 0; ky < filterDim; ky++)
            {
                int nky = filterDim - 1 - ky;
                for (unsigned int kx = 0; kx < filterDim; kx++)
                {
                    int nkx = filterDim - 1 - kx;

                    int yy = y + (ky - filterCenter);
                    int xx = x + (kx - filterCenter);
                    if (xx >= 0 && xx < (int)width && yy >= 0 && yy < (int)height)
                        aggregate += in[yy][xx] * filter[nky * filterDim + nkx];
                }
            }
            aggregate *= filterFactor;
            if (aggregate > 0)
                out[y][x] = (aggregate > 255) ? 255 : aggregate;
            else
                out[y][x] = 0;
        }
    }
}

// GPU - Apply convolutional filter on image data
__global__ void device_applyFilter(unsigned char *out, unsigned char *in, unsigned int width, unsigned int height, int *filter, unsigned int filterDim, float filterFactor)
{
    unsigned int const filterCenter = (filterDim / 2);
    unsigned int x = blockIdx.x * BLOCKX + threadIdx.x;
	unsigned int y = blockIdx.y * BLOCKY + threadIdx.y;
    int aggregate = 0;
    for (unsigned int ky = 0; ky < filterDim; ky++)
    {
        int nky = filterDim - 1 - ky;
        for (unsigned int kx = 0; kx < filterDim; kx++)
        {
            int nkx = filterDim - 1 - kx;

            int yy = y + (ky - filterCenter);
            int xx = x + (kx - filterCenter);
            if (xx >= 0 && xx < (int)width && yy >= 0 && yy < (int)height)
                aggregate += in[xx + yy*width] * filter[nky * filterDim + nkx];
        }
    }
    aggregate *= filterFactor;
    if (x < width && y < height)
    {
        if (aggregate > 0)
            out[x + y*width] = (aggregate > 255) ? 255 : aggregate;
        else
            out[x + y*width] = 0;
    }
}

void help(char const *exec, char const opt, char const *optarg)
{
    FILE *out = stdout;
    if (opt != 0)
    {
        out = stderr;
        if (optarg)
            fprintf(out, "Invalid parameter - %c %s\n", opt, optarg);
        else
            fprintf(out, "Invalid parameter - %c\n", opt);
    }
    fprintf(out, "%s [options] <input-bmp> <output-bmp>\n", exec);
    fprintf(out, "\n");
    fprintf(out, "Options:\n");
    fprintf(out, "  -i, --iterations <iterations>    number of iterations (1)\n");
    fprintf(out, "  -t, --test                       compare GPU and CPU code\n");
    fprintf(out, "\n");
    fprintf(out, "Example: %s in.bmp out.bmp -i 10000\n", exec);
}

double walltime(void)
{
    static struct timeval t;
    gettimeofday(&t, NULL);
    return (t.tv_sec + 1e-6 * t.tv_usec);
}

bool isImageChannelEqual(unsigned char *a, unsigned char *b, unsigned int size)
{
    for (unsigned int i = 0; i < size; i++)
    {
        if (a[i] != b[i])
            return false;
    }
    return true;
}

void freeMemory(char *output, char *input, bmpImage *image, bmpImageChannel *imageChannel1, bmpImageChannel *imageChannel2)
{
    if (output)
        free(output);
    if (input)
        free(input);
    if (image)
        freeBmpImage(image);
    if (imageChannel1)
        freeBmpImageChannel(imageChannel1);
    if (imageChannel2)
        freeBmpImageChannel(imageChannel2);
}

int main(int argc, char **argv)
{
    // Walltime variables
    double startTime;
    double serialTime = 0;
    double cudaTime = 0;

    // Compare GPU and CPU code
    bool test = false;

    // Parameter parsing
    unsigned int iterations = 1;
    char *output = NULL;
    char *input = NULL;
    bmpImage *image = NULL;
    bmpImageChannel *imageChannel1 = NULL;
    bmpImageChannel *imageChannel2 = NULL;

    static struct option const long_options[] = {
        {"help", no_argument, 0, 'h'},
        {"test", no_argument, 0, 't'},
        {"iterations", required_argument, 0, 'i'},
        {0, 0, 0, 0}
    };

    static char const *short_options = "hti:";
    {
        char *endptr;
        int c;
        int option_index = 0;
        while ((c = getopt_long(argc, argv, short_options, long_options, &option_index)) != -1)
        {
            switch (c)
            {
            case 'h':
                help(argv[0], 0, NULL);
                return 0;
            case 't':
                test = true;
                break;
            case 'i':
                iterations = strtol(optarg, &endptr, 10);
                if (endptr == optarg)
                {
                    help(argv[0], c, optarg);
                    return ERROR_EXIT;
                }
                break;
            default:
                abort();
            }
        }
    }

    if (argc <= (optind + 1))
    {
        help(argv[0], ' ', "Not enough arugments");
        return ERROR_EXIT;
    }
    input = (char *)calloc(strlen(argv[optind]) + 1, sizeof(char));
    strncpy(input, argv[optind], strlen(argv[optind]));
    optind++;

    output = (char *)calloc(strlen(argv[optind]) + 1, sizeof(char));
    strncpy(output, argv[optind], strlen(argv[optind]));
    optind++;
    // End of parameter parsing!

    // Create the BMP image and load it from disk.
    image = newBmpImage(0, 0);
    if (image == NULL)
    {
        fprintf(stderr, "Could not allocate new image!\n");
        freeMemory(output, input, image, imageChannel1, imageChannel2);
        return ERROR_EXIT;
    }
    if (loadBmpImage(image, input) != 0)
    {
        fprintf(stderr, "Could not load bmp image '%s'!\n", input);
        freeMemory(output, input, image, imageChannel1, imageChannel2);
        return ERROR_EXIT;
    }

    // Set sizeX and sizeY for image
    unsigned int sizeX = image->width;
    unsigned int sizeY = image->height;

    if (test)
    {
        // Create a single color channel image for CPU code
        imageChannel1 = newBmpImageChannel(sizeX, sizeY);
        if (imageChannel1 == NULL)
        {
            fprintf(stderr, "Could not allocate new image channel 1!\n");
            freeMemory(output, input, image, imageChannel1, imageChannel2);
            return ERROR_EXIT;
        }
        if (extractImageChannel(imageChannel1, image, extractAverage) != 0)
        {
            fprintf(stderr, "Could not extract image channel 1!\n");
            freeMemory(output, input, image, imageChannel1, imageChannel2);
            return ERROR_EXIT;
        }
    }

    // Create a single color channel image for GPU code
    imageChannel2 = newBmpImageChannel(sizeX, sizeY);
    if (imageChannel2 == NULL)
    {
        fprintf(stderr, "Could not allocate new image channel 2!\n");
        freeMemory(output, input, image, imageChannel1, imageChannel2);
        return ERROR_EXIT;
    }
    if (extractImageChannel(imageChannel2, image, extractAverage) != 0)
    {
        fprintf(stderr, "Could not extract image channel 2!\n");
        freeMemory(output, input, image, imageChannel1, imageChannel2);
        return ERROR_EXIT;
    }

    if (test)
    {
        //********************************* CPU work start ***************************
        startTime = walltime();

        // Here we do the actual computation!
        // imageChannel->data is a 2-dimensional array of unsigned char which is accessed row first ([y][x])
        bmpImageChannel *processImageChannel = newBmpImageChannel(sizeX, sizeY);
        for (unsigned int i = 0; i < iterations; i++)
        {
            applyFilter(
                processImageChannel->data,
                imageChannel1->data,
                sizeX,
                sizeY,
                (int *)laplacian1Filter, 3, laplacian1FilterFactor
                //(int *)laplacian2Filter, 3, laplacian2FilterFactor
                //(int *)laplacian3Filter, 3, laplacian3FilterFactor
                //(int *)gaussianFilter, 5, gaussianFilterFactor
            );
            //Swap the data pointers
            unsigned char **tmp = processImageChannel->data;
            processImageChannel->data = imageChannel1->data;
            imageChannel1->data = tmp;
            unsigned char *tmp_raw = processImageChannel->rawdata;
            processImageChannel->rawdata = imageChannel1->rawdata;
            imageChannel1->rawdata = tmp_raw;
        }
        freeBmpImageChannel(processImageChannel);

        serialTime = walltime() - startTime;
        //********************************* CPU work stop ****************************
    }

    //********************************* GPU work start ******************************
    startTime = walltime();

    // Variables
    dim3 gridBlock(sizeX/BLOCKX, sizeY/BLOCKY);
    dim3 threadBlock(BLOCKX, BLOCKY);
    unsigned char *imageChannelGPU = NULL;
    unsigned char *processImageChannelGPU = NULL;
    int *filterGPU = NULL;
    unsigned int filterDim = 3;
    float filterFactor = laplacian1FilterFactor;
    const int *filter = laplacian1Filter;

    // Set up device memory
    cudaErrorCheck(cudaMalloc((void**)&imageChannelGPU, sizeX*sizeY * sizeof(unsigned char)));
    cudaErrorCheck(cudaMalloc((void**)&processImageChannelGPU, sizeX*sizeY * sizeof(unsigned char)));
    cudaErrorCheck(cudaMalloc((void**)&filterGPU, filterDim*filterDim * sizeof(int)));

    // Copy data from host to device
    cudaErrorCheck(cudaMemcpy(imageChannelGPU, imageChannel2->rawdata, sizeX*sizeY * sizeof(unsigned char), cudaMemcpyHostToDevice));
    cudaErrorCheck(cudaMemcpy(filterGPU, filter, filterDim*filterDim * sizeof(int), cudaMemcpyHostToDevice));

    // GPU computation
    for (unsigned int i = 0; i < iterations; i++)
    {
        device_applyFilter<<<gridBlock, threadBlock>>>(
            processImageChannelGPU, 
            imageChannelGPU,
            sizeX,
            sizeY, 
            filterGPU, filterDim, filterFactor
        );
        cudaErrorCheck(cudaGetLastError());
        cudaErrorCheck(cudaMemcpy(imageChannelGPU, processImageChannelGPU, sizeX*sizeY * sizeof(unsigned char), cudaMemcpyDeviceToDevice));
    }

    // Copy data from device to host
    cudaErrorCheck(cudaMemcpy(imageChannel2->rawdata, imageChannelGPU, sizeX*sizeY * sizeof(unsigned char), cudaMemcpyDeviceToHost));

    // Free the device memory
    cudaErrorCheck(cudaFree(imageChannelGPU));
    cudaErrorCheck(cudaFree(processImageChannelGPU));
    cudaErrorCheck(cudaFree(filterGPU));

    cudaTime = walltime() - startTime;
    //********************************* GPU work stop *******************************

    if (test)
    {
        // Check if GPU image channel is equal to CPU image channel
        if (!isImageChannelEqual(imageChannel2->rawdata, imageChannel1->rawdata, sizeX*sizeY))
        {
            fprintf(stderr, "GPU image channel is not equal to serial image channel!\n");
            freeMemory(output, input, image, imageChannel1, imageChannel2);
            return ERROR_EXIT;
        }
    }

    // Map our single color image back to a normal BMP image with 3 color channels
    // mapEqual puts the color value on all three channels the same way
    // other mapping functions are mapRed, mapGreen, mapBlue
    if (mapImageChannel(image, imageChannel2, mapEqual) != 0)
    {
        fprintf(stderr, "Could not map image channel!\n");
        freeMemory(output, input, image, imageChannel1, imageChannel2);
        return ERROR_EXIT;
    }

    //Write the image back to disk
    if (saveBmpImage(image, output) != 0)
    {
        fprintf(stderr, "Could not save output to '%s'!\n", output);
        freeMemory(output, input, image, imageChannel1, imageChannel2);
        return ERROR_EXIT;
    };

    printf("\nGPU time:    %7.3f s    or    %7.3f ms\n", cudaTime, cudaTime * 1e3);
    if (test)
        printf("CPU time:    %7.3f s    or    %7.3f ms\n", serialTime, serialTime * 1e3);

    freeMemory(output, input, image, imageChannel1, imageChannel2);
    return 0;
};
