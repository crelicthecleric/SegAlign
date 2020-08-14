#include <condition_variable>
#include <vector>
#include "graph.h"
#include "parameters.h"
#include "store.h"
#include "tbb/parallel_sort.h"

typedef int(*InitializeProcessor_ptr)(int num_gpu, bool transition, uint32_t WGA_CHUNK, uint32_t input_seed_size, int* sub_mat, int input_xdrop, int input_hspthresh, bool input_noentropy);
typedef void(*InclusivePrefixScan_ptr)(uint32_t* data, uint32_t len);
typedef void(*SendSeedPosTable_ptr)(uint32_t* index_table, uint32_t index_table_size, uint32_t* pos_table, uint32_t ref_size);
typedef void(*SendWriteRequest_ptr)(char* seq, size_t addr, uint32_t len);
typedef std::vector<segment> (*SeedAndFilter_ptr)(std::vector<uint64_t> seed_offset_vector, bool rev, uint32_t ref_start, uint32_t ref_end);
typedef void(*clearRef_ptr)();
typedef void(*ShutdownProcessor_ptr)();

extern InitializeProcessor_ptr g_InitializeProcessor;
extern InclusivePrefixScan_ptr g_InclusivePrefixScan;
extern SendSeedPosTable_ptr g_SendSeedPosTable;
extern SendWriteRequest_ptr g_SendWriteRequest;
extern SeedAndFilter_ptr g_SeedAndFilter;
extern clearRef_ptr g_clearRef;
extern ShutdownProcessor_ptr g_ShutdownProcessor;
