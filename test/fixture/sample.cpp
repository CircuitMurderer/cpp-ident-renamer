#include "sample.hpp"

namespace project {

double Processor::AverageValue = 1.0;

int Processor::GetSize() const {
    return numberOfSlice;
}

bool Processor::IsReady() {
    return AverageValue > 0;
}

int ComputeValue() {
    return 42;
}

String defaultKeyword;
char** names;
char** g_ppsAliases;

} // namespace project
