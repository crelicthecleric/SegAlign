#include <iostream>
#include <thrust/binary_search.h>
#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/scan.h>
#include <thrust/unique.h>
#include "parameters.h"
#include "seed_filter.h"

// Each segment is 16B
// With 64MB for the HSPs array per 1GB GPU memory
// With higher GPU memory, the size just linearly increases

#define MAX_HITS_PER_GB 4194304

// Control Variables
std::mutex mu;
std::condition_variable cv;
std::vector<int> available_gpus;

int NUM_DEVICES;
int MAX_SEEDS;
int MAX_HITS;

uint32_t seed_size;
int **d_sub_mat;
int xdrop;
int hspthresh;
bool noentropy;

char** d_seq;
char** d_seq_rc;
uint32_t seq_len;

uint32_t** d_index_table;
uint32_t** d_pos_table;

uint64_t** d_seed_offsets;

uint32_t** d_hit_num_array;
std::vector<thrust::device_vector<uint32_t> > d_hit_num_vec;

uint32_t** d_done;
std::vector<thrust::device_vector<uint32_t> > d_done_vec;

segment** d_hsp;
std::vector<thrust::device_vector<segment> > d_hsp_vec;

segment** d_hsp_reduced;
std::vector<thrust::device_vector<segment> > d_hsp_reduced_vec;

// wrap of cudaSetDevice error checking in one place.  
static inline void check_cuda_setDevice(int device_id, const char* tag) {
    cudaError_t err = cudaSetDevice(device_id);
    if (err != cudaSuccess) {
        fprintf(stderr, "Error: cudaSetDevice failed for device %d in %s failed with error \" %s \" \n", device_id, tag, cudaGetErrorString(err));
        exit(11);
    }
}

// wrap of cudaMalloc error checking in one place.  
static inline void check_cuda_malloc(void** buf, size_t bytes, const char* tag) {
    cudaError_t err = cudaMalloc(buf, bytes);
    if (err != cudaSuccess) {
        fprintf(stderr, "Error: cudaMalloc of %lu bytes for %s failed with error \" %s \" \n", bytes, tag, cudaGetErrorString(err));
        exit(12);
    }
}
	 
// wrap of cudaMemcpy error checking in one place.  
static inline void check_cuda_memcpy(void* dst_buf, void* src_buf, size_t bytes, cudaMemcpyKind kind, const char* tag) {
    cudaError_t err = cudaMemcpy(dst_buf, src_buf, bytes, kind);
    if (err != cudaSuccess) {
        fprintf(stderr, "Error: cudaMemcpy of %lu bytes for %s failed with error \" %s \" \n", bytes, tag, cudaGetErrorString(err));
        exit(13);
    }
}
	 
// wrap of cudaFree error checking in one place.  
static inline void check_cuda_free(void* buf, const char* tag) {
    cudaError_t err = cudaFree(buf);
    if (err != cudaSuccess) {
        fprintf(stderr, "Error: cudaFree for %s failed with error \" %s \" \n", tag, cudaGetErrorString(err));
        exit(14);
    }
}
	 
struct hspDiagEqual{
    __host__ __device__
        bool operator()(segment x, segment y){
        return ( ( (x.ref_start - x.query_start) == (y.ref_start - y.query_start) ) &&  ( ( (x.ref_start >= y.ref_start) && ( (x.ref_start + x.len) <= (y.ref_start + y.len) )  ) || ( ( y.ref_start >= x.ref_start ) && ( (y.ref_start + y.len) <= (x.ref_start + x.len) ) ) ) );
    }
};

struct hspDiagComp{
    __host__ __device__
        bool operator()(segment x, segment y){
            if((x.ref_start - x.query_start) < (y.ref_start - y.query_start))
                return true;
            else if((x.ref_start - x.query_start) == (y.ref_start - y.query_start)){
                if(x.ref_start < y.ref_start)
                    return true;
                else if(x.ref_start == y.ref_start){
                    if(x.query_start < y.query_start)
                        return true;
                    else if(x.query_start == y.query_start){
                        if(x.score > y.score)
                            return true;
                        else
                            return false;
                    }
                    else
                        return false;
                }
                else
                    return false;
            }
            else 
                return false;
    }
};

struct hspEqual{
    __host__ __device__
        bool operator()(segment x, segment y){
        return ((x.ref_start == y.ref_start) && (x.query_start == y.query_start) && (x.len == y.len) && (x.score == y.score));
    }
};

struct hspFinalComp{
    __host__ __device__
        bool operator()(segment x, segment y){
            if(x.query_start < y.query_start)
                return true;
            else if(x.query_start == y.query_start){
                if(x.score > y.score)
                    return true;
                else if(x.score == y.score){
                    if(x.ref_start > y.ref_start)
                        return true;
                    else
                        return false;
                }
                else
                    return false;
            }
            else
                return false;
    }
};

struct hspComp{
    __host__ __device__
        bool operator()(segment x, segment y){
            if(x.query_start < y.query_start)
                return true;
            else if(x.query_start == y.query_start){
                if(x.len > y.len)
                    return true;
                else if(x.len == y.len){
                    if(x.ref_start < y.ref_start)
                        return true;
                    else if(x.ref_start == y.ref_start){
                        if(x.score > y.score)
                            return true;
                        else
                            return false;
                    }
                    else
                        return false;
                }
                else
                    return false;
            }
            else 
                return false;
    }
};

__global__
void compress_string (uint32_t len, char* src_seq, char* dst_seq){ 
    int thread_id = threadIdx.x;
    int block_dim = blockDim.x;
    int grid_dim = gridDim.x;
    int block_id = blockIdx.x;

    int stride = block_dim * grid_dim;
    uint32_t start = block_dim * block_id + thread_id;

    for (uint32_t i = start; i < len; i += stride) {
        char ch = src_seq[i];
        char dst = X_NT;
        if (ch == 'A')
            dst = A_NT;
        else if (ch == 'C')
            dst = C_NT;
        else if (ch == 'G')
            dst = G_NT;
        else if (ch == 'T')
            dst = T_NT;
        else if ((ch == 'a') || (ch == 'c') || (ch == 'g') || (ch == 't'))
            dst = L_NT;
        else if ((ch == 'n') || (ch == 'N'))
            dst = N_NT;
        else if (ch == '&')
            dst = E_NT;
        dst_seq[i] = dst;
    }
}

__global__
void compress_string_rev_comp (uint32_t len, char* src_seq, char* dst_seq, char* dst_seq_rc){ 
    int thread_id = threadIdx.x;
    int block_dim = blockDim.x;
    int grid_dim = gridDim.x;
    int block_id = blockIdx.x;

    int stride = block_dim * grid_dim;
    uint32_t start = block_dim * block_id + thread_id;

    for (uint32_t i = start; i < len; i += stride) {
        char ch = src_seq[i];
        char dst = X_NT;
        char dst_rc = X_NT;
        if (ch == 'A'){
            dst = A_NT;
            dst_rc = T_NT;
        }
        else if (ch == 'C'){ 
            dst = C_NT;
            dst_rc = G_NT;
        }
        else if (ch == 'G'){
            dst = G_NT;
            dst_rc = C_NT;
        }
        else if (ch == 'T'){
            dst = T_NT;
            dst_rc = A_NT;
        }
        else if ((ch == 'a') || (ch == 'c') || (ch == 'g') || (ch == 't')){
            dst = L_NT;
            dst_rc = L_NT;
        }
        else if ((ch == 'n') || (ch == 'N')){
            dst = N_NT;
            dst_rc = N_NT;
        }
        else if (ch == '&'){
            dst = E_NT;
            dst_rc = E_NT;
        }
        dst_seq[i] = dst;
        dst_seq_rc[len -1 -i] = dst_rc;
    }
}

__global__
void find_num_hits (int num_seeds, const uint32_t* __restrict__ d_index_table, uint64_t* seed_offsets, uint32_t* seed_hit_num){

    int thread_id = threadIdx.x;
    int block_dim = blockDim.x;
    int grid_dim = gridDim.x;
    int block_id = blockIdx.x;

    int stride = block_dim * grid_dim;
    uint32_t start = block_dim * block_id + thread_id;

    uint32_t num_seed_hit;
    uint32_t seed;
    
    for (uint32_t id = start; id < num_seeds; id += stride) {
        seed = (seed_offsets[id] >> 32);

        // start and end from the seed block_id table
        num_seed_hit = d_index_table[seed];
        if (seed > 0){
            num_seed_hit -= d_index_table[seed-1];
        }

        seed_hit_num[id] = num_seed_hit;
    }
}

__global__
void find_hits (const uint32_t* __restrict__  d_index_table, const uint32_t* __restrict__ d_pos_table, uint64_t*  d_seed_offsets, uint32_t seed_size, uint32_t* seed_hit_num, int num_hits, segment* d_hsp, uint32_t start_seed_index, uint32_t start_hit_index, uint32_t ref_start, uint32_t ref_end){

    int thread_id = threadIdx.x;
    int block_id = blockIdx.x;
    int warp_size = warpSize;
    int lane_id = thread_id%warp_size;
    int warp_id = (thread_id-lane_id)/warp_size;

    __shared__ uint32_t start, end;
    __shared__ uint32_t seed;
    __shared__ uint64_t seed_offset;

    __shared__ uint32_t ref_loc[NUM_WARPS];
    __shared__ uint32_t query_loc;
    __shared__ uint32_t seed_hit_prefix;

    if(thread_id == 0){
        seed_offset = d_seed_offsets[block_id+start_seed_index];
        seed = (seed_offset >> 32);
        query_loc = ((seed_offset << 32) >> 32) + seed_size;

        // start and end from the seed block_id table
        end = d_index_table[seed];
        start = 0;
        if (seed > 0){
            start = d_index_table[seed-1];
        }
        seed_hit_prefix = seed_hit_num[block_id+start_seed_index]; 
    }
    __syncthreads();


    for (int id1 = start; id1 < end; id1 += NUM_WARPS) {
        if(id1+warp_id < end){ 
            if(lane_id == 0){ 
                ref_loc[warp_id]   = d_pos_table[id1+warp_id] + seed_size;
                int dram_address = seed_hit_prefix -id1 - warp_id+start-1-start_hit_index;

                d_hsp[dram_address].ref_start = ref_loc[warp_id];
                d_hsp[dram_address].query_start = query_loc; 
                d_hsp[dram_address].len = 0;
                if(ref_loc[warp_id] >= ref_start && ref_loc[warp_id] <= ref_end){
                    d_hsp[dram_address].score = 0;
                }
                else{
                    d_hsp[dram_address].score = -1;
                }
            }
        }
    }
}

__global__
void find_hsps (const char* __restrict__  d_ref_seq, const char* __restrict__  d_query_seq, uint32_t ref_len, uint32_t query_len, int *d_sub_mat, bool noentropy, int xdrop, int hspthresh, int num_hits, segment* d_hsp, uint32_t* d_done){

    int thread_id = threadIdx.x;
    int block_id = blockIdx.x;
    int num_blocks = gridDim.x;
    int warp_size = warpSize;
    int lane_id = thread_id%warp_size;
    int warp_id = (thread_id-lane_id)/warp_size;

    __shared__ uint32_t ref_loc[NUM_WARPS];
    __shared__ uint32_t query_loc[NUM_WARPS];
    __shared__ int total_score[NUM_WARPS];
    __shared__ int prev_score[NUM_WARPS];
    __shared__ int prev_max_score[NUM_WARPS];
    __shared__ int prev_max_pos[NUM_WARPS];
    __shared__ bool find_hsp[NUM_WARPS]; 
    __shared__ bool edge_found[NUM_WARPS]; 
    __shared__ bool xdrop_found[NUM_WARPS]; 
    __shared__ bool new_max_found[NUM_WARPS]; 
    __shared__ uint32_t left_extent[NUM_WARPS];
    __shared__ int extent[NUM_WARPS];
    __shared__ uint32_t tile[NUM_WARPS];
    __shared__ double entropy[NUM_WARPS];

    int thread_score;
    int max_thread_score;
    int max_pos;
    int temp_pos;
    bool xdrop_done;
    bool temp_xdrop_done;
    int temp;
    short count[4];
    short count_del[4];
    char r_chr;
    char q_chr;
    uint32_t ref_pos;
    uint32_t query_pos;
    int pos_offset;

    __shared__ int sub_mat[NUC2];

    if(thread_id < NUC2){
        sub_mat[thread_id] = d_sub_mat[thread_id];
    }
    __syncthreads();

    for(int hid0 = block_id*NUM_WARPS; hid0 < num_hits; hid0 += NUM_WARPS*num_blocks){ 
        int hid = hid0 + warp_id; 

        if(hid < num_hits){
            if(lane_id == 0){
                ref_loc[warp_id] = d_hsp[hid].ref_start;
                query_loc[warp_id] = d_hsp[hid].query_start;
                total_score[warp_id] = 0; 
                if(d_hsp[hid].score < 0){
                    find_hsp = false;
                }
                else{
                    find_hsp = true;
                }
            }
        }
        else{
            if(lane_id == 0){

                ref_loc[warp_id] = d_hsp[hid0].ref_start;
                query_loc[warp_id] = d_hsp[hid0].query_start;
                total_score[warp_id] = 0; 
            }
        }
        __syncwarp();


        //////////////////////////////////////////////////////////////////
        //Right extension

        if(lane_id ==0){
            if(find_hsp){
                edge_found[warp_id] = false;
            }
            else{
                edge_found[warp_id] = true;
            }
            tile[warp_id] = 0;
            xdrop_found[warp_id] = false;
            new_max_found[warp_id] = false;
            entropy[warp_id] = 1.0f;
            prev_score[warp_id] = 0;
            prev_max_score[warp_id] = 0;
            prev_max_pos[warp_id] = -1;
            extent[warp_id] = 0;
        }

        count[0] = 0;
        count[1] = 0;
        count[2] = 0;
        count[3] = 0;
        count_del[0] = 0;
        count_del[1] = 0;
        count_del[2] = 0;
        count_del[3] = 0;
        max_pos = 0;

        __syncwarp();

        while(!xdrop_found[warp_id] && !edge_found[warp_id]){
            pos_offset = lane_id + tile[warp_id];
            ref_pos   = ref_loc[warp_id] + pos_offset;
            query_pos = query_loc[warp_id] + pos_offset;
            thread_score = 0;

            if(ref_pos < ref_len && query_pos < query_len){
                r_chr = d_ref_seq[ref_pos];
                q_chr = d_query_seq[query_pos];
                thread_score = sub_mat[r_chr*NUC+q_chr];
            }
            __syncwarp();

#pragma unroll
            for (int offset = 1; offset < warp_size; offset = offset << 1){
                temp = __shfl_up_sync(0xFFFFFFFF, thread_score, offset);

                if(lane_id >= offset){
                    thread_score += temp;
                }
            }


            thread_score += prev_score[warp_id];
            if(thread_score > prev_max_score[warp_id]){
                max_thread_score = thread_score;
                max_pos = pos_offset;
            }
            else{
                max_thread_score = prev_max_score[warp_id];
                max_pos = prev_max_pos[warp_id];
            }

            __syncwarp();

#pragma unroll
            for (int offset = 1; offset < warp_size; offset = offset << 1){
                temp = __shfl_up_sync(0xFFFFFFFF, max_thread_score, offset);
                temp_pos = __shfl_up_sync(0xFFFFFFFF, max_pos, offset);

                if(lane_id >= offset){
                    if(temp >= max_thread_score){
                        max_thread_score = temp;
                        max_pos = temp_pos;
                    }
                }
            }

            xdrop_done = ((max_thread_score-thread_score) > xdrop);
            __syncwarp();

#pragma unroll
            for (int offset = 1; offset < warp_size; offset = offset << 1){
                temp_xdrop_done = __shfl_up_sync(0xFFFFFFFF, xdrop_done, offset);

                if(lane_id >= offset){
                    xdrop_done |= temp_xdrop_done;
                }
            }

            if(xdrop_done == 1){
                max_thread_score = prev_max_score[warp_id];
                max_pos = prev_max_pos[warp_id];
            }
            __syncwarp();

#pragma unroll
            for (int offset = 1; offset < warp_size; offset = offset << 1){
                temp = __shfl_up_sync(0xFFFFFFFF, max_thread_score, offset);
                temp_pos = __shfl_up_sync(0xFFFFFFFF, max_pos, offset);

                if(lane_id >= offset){
                    if(temp >= max_thread_score){
                        max_thread_score = temp;
                        max_pos = temp_pos;
                    }
                }
            }
            __syncwarp();

            if(lane_id == warp_size-1){

                if(max_pos > prev_max_pos[warp_id])
                    new_max_found[warp_id] = true;
                else
                    new_max_found[warp_id] = false;

                if(xdrop_done){
                    total_score[warp_id] += max_thread_score;
                    xdrop_found[warp_id] = true;
                    extent[warp_id] = max_pos;
                    prev_max_pos[warp_id] = max_pos;
                    tile[warp_id] = max_pos;
                }
                else if(ref_pos >= ref_len || query_pos >= query_len){
                    total_score[warp_id] += max_thread_score;
                    edge_found[warp_id] = true;
                    extent[warp_id] = max_pos;
                    prev_max_pos[warp_id] = max_pos;
                    tile[warp_id] = max_pos;
                }
                else{
                    prev_score[warp_id] = thread_score;
                    prev_max_score[warp_id] = max_thread_score;
                    prev_max_pos[warp_id] = max_pos;
                    tile[warp_id]+= warp_size;
                }
            }
            __syncwarp();

            if(new_max_found[warp_id]){
                for(int i = 0; i < 4; i++){
                    count[i] = count[i] + count_del[i];
                    count_del[i] = 0;
                }
            }
            __syncwarp();

            if(r_chr == q_chr){
                if(pos_offset <= prev_max_pos[warp_id]){
                    count[r_chr] += 1;
                }
                else{
                    count_del[r_chr] += 1;
                }
            }
            __syncwarp();

        }

        __syncwarp();

        ////////////////////////////////////////////////////////////////
        //Left extension

        if(lane_id ==0){
            if(find_hsp){
                edge_found[warp_id] = false;
            }
            else{
                edge_found[warp_id] = true;
            }
            tile[warp_id] = 0;
            xdrop_found[warp_id] = false;
            new_max_found[warp_id] = false;
            prev_score[warp_id] = 0;
            prev_max_score[warp_id] = 0;
            prev_max_pos[warp_id] = 0;
            left_extent[warp_id] = 0;
        }

        count_del[0] = 0;
        count_del[1] = 0;
        count_del[2] = 0;
        count_del[3] = 0;
        max_pos = 0;
        __syncwarp();

        while(!xdrop_found[warp_id] && !edge_found[warp_id]){
            pos_offset = lane_id+1+tile[warp_id];
            thread_score = 0;

            if(ref_loc[warp_id] >= pos_offset  && query_loc[warp_id] >= pos_offset){
                ref_pos   = ref_loc[warp_id] - pos_offset;
                query_pos = query_loc[warp_id] - pos_offset;
                r_chr = d_ref_seq[ref_pos];
                q_chr = d_query_seq[query_pos];
                thread_score = sub_mat[r_chr*NUC+q_chr];
            }

#pragma unroll
            for (int offset = 1; offset < warp_size; offset = offset << 1){
                temp = __shfl_up_sync(0xFFFFFFFF, thread_score, offset);

                if(lane_id >= offset){
                    thread_score += temp;
                }
            }

            thread_score += prev_score[warp_id];
            if(thread_score > prev_max_score[warp_id]){
                max_thread_score = thread_score;
                max_pos = pos_offset;
            }
            else{
                max_thread_score = prev_max_score[warp_id];
                max_pos = prev_max_pos[warp_id];
            }
            __syncwarp();

#pragma unroll
            for (int offset = 1; offset < warp_size; offset = offset << 1){
                temp = __shfl_up_sync(0xFFFFFFFF, max_thread_score, offset);
                temp_pos = __shfl_up_sync(0xFFFFFFFF, max_pos, offset);

                if(lane_id >= offset){
                    if(temp >= max_thread_score){
                        max_thread_score = temp;
                        max_pos = temp_pos;
                    }
                }
            }

            xdrop_done = ((max_thread_score-thread_score) > xdrop);
            __syncwarp();

#pragma unroll
            for (int offset = 1; offset < warp_size; offset = offset << 1){
                temp_xdrop_done = __shfl_up_sync(0xFFFFFFFF, xdrop_done, offset);

                if(lane_id >= offset){
                    xdrop_done |= temp_xdrop_done;
                }
            }

            if(xdrop_done == 1){
                max_thread_score = prev_max_score[warp_id];
                max_pos = prev_max_pos[warp_id];
            }
            __syncwarp();

#pragma unroll
            for (int offset = 1; offset < warp_size; offset = offset << 1){
                temp = __shfl_up_sync(0xFFFFFFFF, max_thread_score, offset);
                temp_pos = __shfl_up_sync(0xFFFFFFFF, max_pos, offset);

                if(lane_id >= offset){
                    if(temp >= max_thread_score){
                        max_thread_score = temp;
                        max_pos = temp_pos;
                    }
                }
            }
            __syncwarp();

            if(lane_id == warp_size-1){

                if(max_pos > prev_max_pos[warp_id])
                    new_max_found[warp_id] = true;
                else
                    new_max_found[warp_id] = false;

                if(xdrop_done){
                    total_score[warp_id]+=max_thread_score;
                    xdrop_found[warp_id] = true;
                    left_extent[warp_id] = max_pos;
                    extent[warp_id] += left_extent[warp_id];
                    prev_max_pos[warp_id] = max_pos;
                    tile[warp_id] = max_pos;
                }
                else if(ref_loc[warp_id] < pos_offset || query_loc[warp_id] < pos_offset){
                    total_score[warp_id]+=max_thread_score;
                    edge_found[warp_id] = true;
                    left_extent[warp_id] = max_pos;
                    extent[warp_id] += left_extent[warp_id];
                    prev_max_pos[warp_id] = max_pos;
                    tile[warp_id] = max_pos;
                }
                else{
                    prev_score[warp_id] = thread_score;
                    prev_max_score[warp_id] = max_thread_score;
                    prev_max_pos[warp_id] = max_pos;
                    tile[warp_id]+=warp_size;
                }
            }
            __syncwarp();

            if(new_max_found[warp_id]){
                for(int i = 0; i < 4; i++){
                    count[i] = count[i] + count_del[i];
                    count_del[i] = 0;
                }
            }
            __syncwarp();

            if(r_chr == q_chr){
                if(pos_offset <= prev_max_pos[warp_id]){
                    count[r_chr] += 1;
                }
                else{
                    count_del[r_chr] += 1;
                }
            }
            __syncwarp();

        }

        //////////////////////////////////////////////////////////////////

        if(total_score[warp_id] >= hspthresh && total_score[warp_id] <= 3*hspthresh && !noentropy){
            for(int i = 0; i < 4; i++){
#pragma unroll
                for (int offset = 1; offset < warp_size; offset = offset << 1){
                    count[i] += __shfl_up_sync(0xFFFFFFFF, count[i], offset);
                }
            }
            __syncwarp();

            if(lane_id == warp_size-1 && ((count[0]+count[1]+count[2]+count[3]) >= 20)){

                entropy[warp_id] = 0.f;
                for(int i = 0; i < 4; i++){
                    entropy[warp_id] += ((double) count[i])/((double) (extent[warp_id]+1)) * ((count[i] != 0) ? log(((double) count[i]) / ((double) (extent[warp_id]+1))): 0.f); 
                }
                entropy[warp_id] = -entropy[warp_id]/log(4.0f);
            }
        }
        __syncwarp();

        //////////////////////////////////////////////////////////////////

        if(hid < num_hits){
            if(lane_id == 0){

                if( ((int) (((float) total_score[warp_id])  * entropy[warp_id])) >= hspthresh){
                    d_hsp[hid].ref_start = ref_loc[warp_id] - left_extent[warp_id];
                    d_hsp[hid].query_start = query_loc[warp_id] - left_extent[warp_id];
                    d_hsp[hid].len = extent[warp_id];
                    if(entropy[warp_id] > 0)
                        d_hsp[hid].score = total_score[warp_id]*entropy[warp_id];
                    d_done[hid] = 1;
                }
                else{
                    d_hsp[hid].ref_start = ref_loc[warp_id];
                    d_hsp[hid].query_start = query_loc[warp_id];
                    d_hsp[hid].len = 0;
                    d_hsp[hid].score = 0;
                    d_done[hid] = 0;
                }
            }
        }
        __syncwarp();
    }
}

__global__
void compress_output (uint32_t* d_done, segment* d_hsp, segment* d_hsp_reduced, int num_hits){

    int thread_id = threadIdx.x;
    int block_dim = blockDim.x;
    int grid_dim = gridDim.x;
    int block_id = blockIdx.x;

    int stride = block_dim * grid_dim;
    uint32_t start = block_dim * block_id + thread_id;
    int index = 0;

    for (uint32_t id = start; id < num_hits; id += stride) {
        index = d_done[id];

        if(id > 0){
            if(index > d_done[id-1]){
                d_hsp_reduced[index-1] = d_hsp[id];
            }
        }
        else{
            if(index == 1){
                d_hsp_reduced[0] = d_hsp[0];
            }
        }
    }
}

std::vector<segment> SeedAndFilter (std::vector<uint64_t> seed_offset_vector, bool rev, uint32_t ref_start, uint32_t ref_end){

    uint32_t num_hits = 0;
    uint32_t total_anchors = 0;

    uint32_t num_seeds = seed_offset_vector.size();
    assert(num_seeds <= MAX_SEEDS);

    uint64_t* tmp_offset = (uint64_t*) malloc(num_seeds*sizeof(uint64_t));
    for (uint32_t i = 0; i < num_seeds; i++) {
        tmp_offset[i] = seed_offset_vector[i];
    }

    int g;
    std::unique_lock<std::mutex> locker(mu);
    if (available_gpus.empty()) {
        cv.wait(locker, [](){return !available_gpus.empty();});
    }
    g = available_gpus.back();
    available_gpus.pop_back();
    locker.unlock();

    check_cuda_setDevice(g, "SeedAndFilter");

    check_cuda_memcpy((void*)d_seed_offsets[g], (void*)tmp_offset, num_seeds*sizeof(uint64_t), cudaMemcpyHostToDevice, "seed_offsets");

    find_num_hits <<<MAX_BLOCKS, MAX_THREADS>>> (num_seeds, d_index_table[g], d_seed_offsets[g], d_hit_num_array[g]);

    thrust::inclusive_scan(d_hit_num_vec[g].begin(), d_hit_num_vec[g].begin() + num_seeds, d_hit_num_vec[g].begin());

    check_cuda_memcpy((void*)&num_hits, (void*)(d_hit_num_array[g]+num_seeds-1), sizeof(uint32_t), cudaMemcpyDeviceToHost, "num_hits");
    
    int num_iter = num_hits/MAX_HITS+1;
    uint32_t iter_hit_limit = MAX_HITS;
    thrust::device_vector<uint32_t> limit_pos (num_iter); 

    for(int i = 0; i < num_iter-1; i++){
        thrust::device_vector<uint32_t>::iterator result_end = thrust::lower_bound(d_hit_num_vec[g].begin(), d_hit_num_vec[g].begin()+num_seeds, iter_hit_limit);
        uint32_t pos = thrust::distance(d_hit_num_vec[g].begin(), result_end)-1;
        iter_hit_limit = d_hit_num_vec[g][pos]+MAX_HITS;
        limit_pos[i] = pos;
    }

    limit_pos[num_iter-1] = num_seeds-1;

    segment** h_hsp = (segment**) malloc(num_iter*sizeof(segment*));
    uint32_t* num_anchors = (uint32_t*) calloc(num_iter, sizeof(uint32_t));

    uint32_t start_seed_index = 0;
    uint32_t start_hit_val = 0;
    uint32_t iter_num_seeds, iter_num_hits;

    if(num_hits > 0){
        
        for(int i = 0; i < num_iter; i++){
            iter_num_seeds = limit_pos[i] + 1 - start_seed_index;
            iter_num_hits  = d_hit_num_vec[g][limit_pos[i]] - start_hit_val;

            find_hits <<<iter_num_seeds, BLOCK_SIZE>>> (d_index_table[g], d_pos_table[g], d_seed_offsets[g], seed_size, d_hit_num_array[g], iter_num_hits, d_hsp[g], start_seed_index, start_hit_val, ref_start, ref_end);

            if(rev){
                find_hsps <<<1024, BLOCK_SIZE>>> (d_seq[g], d_seq_rc[g], seq_len, seq_len, d_sub_mat[g], noentropy, xdrop, hspthresh, iter_num_hits, d_hsp[g], d_done[g]);
            }
            else{
                find_hsps <<<1024, BLOCK_SIZE>>> (d_seq[g], d_seq[g], seq_len, seq_len, d_sub_mat[g], noentropy, xdrop, hspthresh, iter_num_hits, d_hsp[g], d_done[g]);
            }

            thrust::inclusive_scan(d_done_vec[g].begin(), d_done_vec[g].begin() + iter_num_hits, d_done_vec[g].begin());

            check_cuda_memcpy((void*)&num_anchors[i], (void*)(d_done[g]+iter_num_hits-1), sizeof(uint32_t), cudaMemcpyDeviceToHost, "num_anchors");

            if(num_anchors[i] > 0){
                compress_output <<<MAX_BLOCKS, MAX_THREADS>>>(d_done[g], d_hsp[g], d_hsp_reduced[g], iter_num_hits);

                thrust::stable_sort(d_hsp_reduced_vec[g].begin(), d_hsp_reduced_vec[g].begin()+num_anchors[i], hspComp());
                
                thrust::device_vector<segment>::iterator result_end = thrust::unique_copy(d_hsp_reduced_vec[g].begin(), d_hsp_reduced_vec[g].begin()+num_anchors[i], d_hsp_vec[g].begin(),  hspEqual());

                num_anchors[i] = thrust::distance(d_hsp_vec[g].begin(), result_end), num_anchors[i];

                thrust::stable_sort(d_hsp_vec[g].begin(), d_hsp_vec[g].begin()+num_anchors[i], hspDiagComp());
                
                thrust::device_vector<segment>::iterator result_end2 = thrust::unique_copy(d_hsp_vec[g].begin(), d_hsp_vec[g].begin()+num_anchors[i], d_hsp_reduced_vec[g].begin(),  hspDiagEqual());

                num_anchors[i] = thrust::distance(d_hsp_reduced_vec[g].begin(), result_end2), num_anchors[i];

                thrust::stable_sort(d_hsp_reduced_vec[g].begin(), d_hsp_reduced_vec[g].begin()+num_anchors[i], hspFinalComp());

                total_anchors += num_anchors[i];

                h_hsp[i] = (segment*) calloc(num_anchors[i], sizeof(segment));

                check_cuda_memcpy((void*)h_hsp[i], (void*)d_hsp_reduced[g], num_anchors[i]*sizeof(segment), cudaMemcpyDeviceToHost, "hsp_output");
            }

            start_seed_index = limit_pos[i] + 1;
            start_hit_val = d_hit_num_vec[g][limit_pos[i]];
        }
    }

    limit_pos.clear();

    {
        std::unique_lock<std::mutex> locker(mu);
        available_gpus.push_back(g);
        locker.unlock();
        cv.notify_one();
    }
    std::vector<segment> gpu_filter_output;

    segment first_el;
    first_el.len = total_anchors;
    first_el.score = num_hits;
    gpu_filter_output.push_back(first_el);

    if(total_anchors > 0){
        for(int it = 0; it < num_iter; it++){

            for(int i = 0; i < num_anchors[it]; i++){
                gpu_filter_output.push_back(h_hsp[it][i]);
            }
        }
        free(h_hsp);
    }
    
    free(tmp_offset);
    return gpu_filter_output;
}

int InitializeProcessor (int num_gpu, bool transition, uint32_t WGA_CHUNK, uint32_t input_seed_size, int* sub_mat, int input_xdrop, int input_hspthresh, bool input_noentropy){

    int nDevices;

    cudaError_t err = cudaGetDeviceCount(&nDevices);
    if (err != cudaSuccess) {
        fprintf(stderr, "Error: No GPU device found!\n");
        exit(1);
    }

    if(num_gpu == -1){
        NUM_DEVICES = nDevices; 
    }
    else{
        if(num_gpu <= nDevices){
            NUM_DEVICES = num_gpu;
        }
        else{
            fprintf(stderr, "Requested GPUs greater than available GPUs\n");
            exit(10);
        }
    }

    fprintf(stderr, "Using %d GPU(s)\n", NUM_DEVICES);

    cudaDeviceProp deviceProp;
    cudaGetDeviceProperties(&deviceProp, 0);
    float global_mem_gb = static_cast<float>(deviceProp.totalGlobalMem / 1073741824.0f);

    if(transition)
        MAX_SEEDS = 13*WGA_CHUNK;
    else
        MAX_SEEDS = WGA_CHUNK;

    MAX_HITS = MAX_HITS_PER_GB*global_mem_gb;

    seed_size = input_seed_size;
    xdrop = input_xdrop;
    hspthresh = input_hspthresh;
    noentropy = input_noentropy;

    d_sub_mat = (int**) malloc(NUM_DEVICES*sizeof(int*));

    d_seq = (char**) malloc(NUM_DEVICES*sizeof(char*));
    d_seq_rc = (char**) malloc(NUM_DEVICES*sizeof(char*));
    
    d_index_table = (uint32_t**) malloc(NUM_DEVICES*sizeof(uint32_t*));
    d_pos_table = (uint32_t**) malloc(NUM_DEVICES*sizeof(uint32_t*));

    d_seed_offsets = (uint64_t**) malloc(NUM_DEVICES*sizeof(uint64_t*));

    d_hit_num_array = (uint32_t**) malloc(NUM_DEVICES*sizeof(uint32_t*));
    d_hit_num_vec.reserve(NUM_DEVICES);

    d_done = (uint32_t**) malloc(NUM_DEVICES*sizeof(uint32_t*));
    d_done_vec.reserve(NUM_DEVICES);

    d_hsp = (segment**) malloc(NUM_DEVICES*sizeof(segment*));
    d_hsp_vec.reserve(NUM_DEVICES);

    d_hsp_reduced = (segment**) malloc(NUM_DEVICES*sizeof(segment*));
    d_hsp_reduced_vec.reserve(NUM_DEVICES);

    segment zeroHsp;
    zeroHsp.ref_start = 0;
    zeroHsp.query_start = 0;
    zeroHsp.len = 0;
    zeroHsp.score = 0;

    for(int g = 0; g < NUM_DEVICES; g++){

        check_cuda_setDevice(g, "InitializeProcessor");

        check_cuda_malloc((void**)&d_sub_mat[g], NUC2*sizeof(int), "sub_mat"); 

        check_cuda_memcpy((void*)d_sub_mat[g], (void*)sub_mat, NUC2*sizeof(int), cudaMemcpyHostToDevice, "sub_mat");

        check_cuda_malloc((void**)&d_seed_offsets[g], MAX_SEEDS*sizeof(uint64_t), "seed_offsets");

        d_hit_num_vec.emplace_back(MAX_SEEDS, 0);
        d_hit_num_array[g] = thrust::raw_pointer_cast(d_hit_num_vec.at(g).data());

        d_done_vec.emplace_back(MAX_HITS, 0);
        d_done[g] = thrust::raw_pointer_cast(d_done_vec.at(g).data());

        d_hsp_vec.emplace_back(MAX_HITS, zeroHsp);
        d_hsp[g] = thrust::raw_pointer_cast(d_hsp_vec.at(g).data());

        d_hsp_reduced_vec.emplace_back(MAX_HITS, zeroHsp);
        d_hsp_reduced[g] = thrust::raw_pointer_cast(d_hsp_reduced_vec.at(g).data());

        available_gpus.push_back(g);
    }
    
    return NUM_DEVICES;
}

void InclusivePrefixScan (uint32_t* data, uint32_t len) {
    int g;
    
    {
        std::unique_lock<std::mutex> locker(mu);
        if (available_gpus.empty()) {
            cv.wait(locker, [](){return !available_gpus.empty();});
        }
        g = available_gpus.back();
        available_gpus.pop_back();
        locker.unlock();

        check_cuda_setDevice(g, "InclusivePrefixScan");
    }

    thrust::inclusive_scan(thrust::host, data, data + len, data); 

    {
        std::unique_lock<std::mutex> locker(mu);
        available_gpus.push_back(g);
        locker.unlock();
        cv.notify_one();
    }
}

void SendSeedPosTable (uint32_t* index_table, uint32_t index_table_size, uint32_t* pos_table, uint32_t num_index){

    for(int g = 0; g < NUM_DEVICES; g++){

        check_cuda_setDevice(g, "SendSeedPosTable");

        check_cuda_malloc((void**)&d_index_table[g], index_table_size*sizeof(uint32_t), "index_table"); 

        check_cuda_memcpy((void*)d_index_table[g], (void*)index_table, index_table_size*sizeof(uint32_t), cudaMemcpyHostToDevice, "index_table");

        check_cuda_malloc((void**)&d_pos_table[g], num_index*sizeof(uint32_t), "pos_table"); 

        check_cuda_memcpy((void*)d_pos_table[g], (void*)pos_table, num_index*sizeof(uint32_t), cudaMemcpyHostToDevice, "pos_table");
    }
}

void SendRefWriteRequest (size_t start_addr, uint32_t len){

    seq_len = len;
    
    for(int g = 0; g < NUM_DEVICES; g++){

        check_cuda_setDevice(g, "SendRefWriteRequest");

        char* d_seq_tmp;
        check_cuda_malloc((void**)&d_seq_tmp, len*sizeof(char), "d_seq_tmp"); 

        check_cuda_memcpy((void*)d_seq_tmp, (void*)(seq_DRAM->buffer + start_addr), len*sizeof(char), cudaMemcpyHostToDevice, "seq");

        check_cuda_malloc((void**)&d_seq[g], len*sizeof(char), "seq"); 
        check_cuda_malloc((void**)&d_seq_rc[g], len*sizeof(char), "seq_rc"); 

        compress_string_rev_comp <<<MAX_BLOCKS, MAX_THREADS>>> (len, d_seq_tmp, d_seq[g], d_seq_rc[g]);

        check_cuda_free((void*)d_seq_tmp, "d_seq_tmp");
    }
}

void clearRef(){

    for(int g = 0; g < NUM_DEVICES; g++){

        check_cuda_setDevice(g, "clearRef");

        check_cuda_free((void*)d_seq[g], "d_seq");
        check_cuda_free((void*)d_seq_rc[g], "d_seq_rc");
        check_cuda_free((void*)d_index_table[g], "d_index_table");
        check_cuda_free((void*)d_pos_table[g], "d_pos_table");
    }
}

void ShutdownProcessor(){

    d_done_vec.clear();
    d_hit_num_vec.clear();
    d_hsp_vec.clear();
    d_hsp_reduced_vec.clear();

    cudaDeviceReset();
}

InitializeProcessor_ptr g_InitializeProcessor = InitializeProcessor;
InclusivePrefixScan_ptr g_InclusivePrefixScan = InclusivePrefixScan;
SendSeedPosTable_ptr g_SendSeedPosTable = SendSeedPosTable;
SendRefWriteRequest_ptr g_SendRefWriteRequest = SendRefWriteRequest;
SeedAndFilter_ptr g_SeedAndFilter = SeedAndFilter;
clearRef_ptr g_clearRef = clearRef;
ShutdownProcessor_ptr g_ShutdownProcessor = ShutdownProcessor;
