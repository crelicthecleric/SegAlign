#include <atomic>
#include "ntcoding.h"
#include "graph.h"

std::mutex io_lock;
int print_header = 1;

void segment_printer_body::operator()(printer_input input, printer_node::output_ports_type & op){
    auto &payload = get<0>(input); 
    size_t token = get<1>(input);

    auto &index = get<0>(payload);
    auto &fw_segments = get<1>(payload);
    auto &rc_segments = get<2>(payload);

    std::string filename = "tmp"+std::to_string(index)+".segments";
    FILE* segment_file = fopen(filename.c_str(), "w");

    for (auto e: fw_segments) {

        if (print_header == 1) {
            io_lock.lock();
            fprintf(segment_file, "#name1\tstart1\tend1\tname2\tstart2\tend2\tstrand2\tscore\n");
            printf("%s\n", filename.c_str());
            print_header = 0;
            io_lock.unlock();
        }

        io_lock.lock();
        fprintf(segment_file, "ce11.chr1\t%d\t%d\tcb4.chr1\t%d\t%d\t+\t%d\n", (e.ref_start+1), (e.ref_start+e.len), (e.query_start+1), (e.query_start+e.len), e.score);
        io_lock.unlock();
    }

    for (auto e: rc_segments) {

        io_lock.lock();
        fprintf(segment_file, "ce11.chr1\t%d\t%d\tcb4.chr1\t%d\t%d\t-\t%d\n", (e.ref_start+1), (e.ref_start+e.len), (e.query_start+1), (e.query_start+e.len), e.score);
        io_lock.unlock();
    }

    get<0>(op).try_put(token);
};