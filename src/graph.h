#pragma once
#define BOOST_LOCALE_NO_LIB
#define NOMINMAX
#include <atomic>
#include <string>
#include <tbb/flow_graph.h>
#include <vector>
#include "seed_pos_table.h"

using namespace tbb::flow;

struct Configuration {
    //Input files/folder name
    std::string reference_filename;

    // Sequence parameters
    std::string strand;
    uint32_t num_neigh_interval;
    uint32_t ref_len;
    uint32_t num_ref;

    // Scoring
    std::string scoring_file;
    std::string ambiguous;
    int sub_mat[NUC2];

    // Seed parameters
    std::string seed_shape;
    bool transition;
    uint32_t step;
    std::string seed;
    uint32_t seed_size;
    
    // Filter parameters
    int xdrop; 
    int hspthresh;
    bool noentropy;

    // Extension parameters
    bool gapped;
    int ydrop;
    int gappedthresh;
    bool notrivial;

    // Output parameters
    std::string output_format;
    std::string output;
    bool markend;

    // System parameters
    uint32_t wga_chunk_size;
    uint32_t lastz_interval_size;
    uint32_t seq_block_size;
    int num_gpu;
    int num_threads;
    bool debug;
};

extern Configuration cfg;
extern SeedPosTable *sa;

struct seq_block {
  int index;
  size_t start;
  uint32_t len;
};

struct seed_interval {
    uint32_t start;
    uint32_t end;
    uint32_t ref_start;
    uint32_t ref_end;
    uint32_t num_invoked;
    uint32_t num_intervals;
};

typedef std::vector<segment> hsp_output; 
typedef tbb::flow::tuple <seq_block, seed_interval> seeder_payload;
typedef tbb::flow::tuple <seq_block, int, hsp_output, hsp_output> printer_payload;
typedef tbb::flow::tuple <seeder_payload, size_t> seeder_input;
typedef tbb::flow::tuple <printer_payload, size_t> printer_input;
typedef tbb::flow::multifunction_node<printer_input, tbb::flow::tuple<size_t>> printer_node;

struct seeder_body{
	static std::atomic<uint64_t> num_seed_hits;
	static std::atomic<uint64_t> num_seeds;
	static std::atomic<uint64_t> num_hsps;
    static std::atomic<uint32_t> total_xdrop;
    static std::atomic<uint32_t> num_seeded_regions;
	printer_input operator()(seeder_input input);
};

struct segment_printer_body{
	void operator()(printer_input input, printer_node::output_ports_type & op);
};

