/******************************************************************************
 *
 * Copyright 2010-2011 Duane Merrill
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a scan of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 * 
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 ******************************************************************************/


/******************************************************************************
 * Simple test driver program for radix sort.
 ******************************************************************************/

#include <stdio.h> 
#include <algorithm>

// Sorting includes
#include <b40c/util/ping_pong_storage.cuh>
#include <b40c/util/io/modified_load.cuh>
#include <b40c/util/io/modified_store.cuh>

#include <b40c/radix_sort/problem_type.cuh>
#include <b40c/radix_sort/policy.cuh>
#include <b40c/radix_sort/enactor.cuh>

// Test utils
#include "b40c_test_util.h"

/******************************************************************************
 * Problem / Tuning Policy Types
 ******************************************************************************/

/**
 * Sample sorting problem type (32-bit keys and 32-bit values)
 */
typedef b40c::radix_sort::ProblemType<
		unsigned int,						// Key type
//		unsigned int,						// Value type
		b40c::util::NullType,				// Value type (alternatively, use b40c::util::NullType for keys-only sorting)
		int> 								// SizeT (what type to use for counting)
	ProblemType;

template <int CUDA_ARCH>
struct SortingPolicy;

/**
 * SM20
 */
template <>
struct SortingPolicy<200> : ProblemType
{
	template <int BITS, int DUMMY = 0>
	struct BitPolicy
	{
		typedef b40c::radix_sort::Policy<
				ProblemType,				// Problem type

				// Common
				200,						// SM ARCH
				CUB_MIN(BITS, 5),			// RADIX_BITS

				// Launch tuning policy
				12,							// LOG_SCHEDULE_GRANULARITY			The "grain" by which to divide up the problem input.  E.g., 7 implies a near-even distribution of 128-key chunks to each CTA.  Related to, but different from the upsweep/downswep tile sizes, which may be different from each other.
				b40c::util::io::ld::NONE,	// CACHE_MODIFIER					Load cache-modifier.  Valid values: NONE, ca, cg, cs
				b40c::util::io::st::NONE,	// CACHE_MODIFIER					Store cache-modifier.  Valid values: NONE, wb, cg, cs
				false,						// EARLY_EXIT						Whether or not to early-terminate a sorting pass if we detect all keys have the same digit in that pass's digit place
				false,						// UNIFORM_SMEM_ALLOCATION			Whether or not to pad the dynamic smem allocation to ensure that all three kernels (upsweep, spine, downsweep) have the same overall smem allocation
				true, 						// UNIFORM_GRID_SIZE				Whether or not to launch the spine kernel with one CTA (all that's needed), or pad it up to the same grid size as the upsweep/downsweep kernels
				true,						// OVERSUBSCRIBED_GRID_SIZE			Whether or not to oversubscribe the GPU with CTAs, up to a constant factor (usually 4x the resident occupancy)

				// Policy for upsweep kernel.
				// 		Reduces/counts all the different digit numerals for a given digit-place
				//
				8,							// UPSWEEP_CTA_OCCUPANCY			The targeted SM occupancy to feed PTXAS in order to influence how it does register allocation
				7,							// UPSWEEP_LOG_THREADS				The number of threads (log) to launch per CTA.  Valid range: 5-10
				2,							// UPSWEEP_LOG_LOAD_VEC_SIZE		The vector-load size (log) for each load (log).  Valid range: 0-2
				1,							// UPSWEEP_LOG_LOADS_PER_TILE		The number of loads (log) per tile.  Valid range: 0-2

				// Spine-scan kernel policy
				//		Prefix sum of upsweep histograms counted by each CTA.  Relatively insignificant in the grand scheme, not really worth tuning for large problems)
				//
				8,							// SPINE_LOG_THREADS				The number of threads (log) to launch per CTA.  Valid range: 5-10
				2,							// SPINE_LOG_LOAD_VEC_SIZE			The vector-load size (log) for each load (log).  Valid range: 0-2
				2,							// SPINE_LOG_LOADS_PER_TILE			The number of loads (log) per tile.  Valid range: 0-2
				5,							// SPINE_LOG_RAKING_THREADS			The number of raking threads (log) for local prefix sum.  Valid range: 5-SPINE_LOG_THREADS

				// Policy for downsweep kernel
				//		Given prefix counts, scans/scatters keys into appropriate bins
				// 		Note: a "cycle" is a tile sub-segment up to 256 keys
				//
				b40c::partition::downsweep::SCATTER_TWO_PHASE,			// DOWNSWEEP_TWO_PHASE_SCATTER		Whether or not to perform a two-phase scatter (scatter to smem first to recover some locality before scattering to global bins)
				ProblemType::KEYS_ONLY ? 4 : 2,							// DOWNSWEEP_CTA_OCCUPANCY			The targeted SM occupancy to feed PTXAS in order to influence how it does register allocation
				ProblemType::KEYS_ONLY ? 7 : 8,							// DOWNSWEEP_LOG_THREADS			The number of threads (log) to launch per CTA.  Valid range: 5-10, subject to constraints described above
				ProblemType::KEYS_ONLY ? 4 : 4,							// DOWNSWEEP_LOG_LOAD_VEC_SIZE		The vector-load size (log) for each load (log).  Valid range: 0-2, subject to constraints described above
				0,														// DOWNSWEEP_LOG_LOADS_PER_TILE		The number of loads (log) per tile.  Valid range: 0-2
				ProblemType::KEYS_ONLY ? 7 : 8>							// DOWNSWEEP_LOG_RAKING_THREADS		The number of raking threads (log) for local prefix sum.  Valid range: 5-DOWNSWEEP_LOG_THREADS
			Policy;
	};

};


/**
 * SM13
 */
template <>
struct SortingPolicy<130> : ProblemType
{
	template <int BITS, int DUMMY = 0>
	struct BitPolicy
	{
		enum
		{
			KEY_BITS = CUB_MIN(BITS, 5)
		};

		typedef b40c::radix_sort::Policy<
				ProblemType,				// Problem type

				// Common
				130,						// SM ARCH
				KEY_BITS,					// RADIX_BITS

				// Launch tuning policy
				10,							// LOG_SCHEDULE_GRANULARITY			The "grain" by which to divide up the problem input.  E.g., 7 implies a near-even distribution of 128-key chunks to each CTA.  Related to, but different from the upsweep/downswep tile sizes, which may be different from each other.
				b40c::util::io::ld::NONE,	// CACHE_MODIFIER					Load cache-modifier.  Valid values: NONE, ca, cg, cs
				b40c::util::io::st::NONE,	// CACHE_MODIFIER					Store cache-modifier.  Valid values: NONE, wb, cg, cs
				false,						// EARLY_EXIT						Whether or not to early-terminate a sorting pass if we detect all keys have the same digit in that pass's digit place
				true,						// UNIFORM_SMEM_ALLOCATION			Whether or not to pad the dynamic smem allocation to ensure that all three kernels (upsweep, spine, downsweep) have the same overall smem allocation
				true, 						// UNIFORM_GRID_SIZE				Whether or not to launch the spine kernel with one CTA (all that's needed), or pad it up to the same grid size as the upsweep/downsweep kernels
				true,						// OVERSUBSCRIBED_GRID_SIZE			Whether or not to oversubscribe the GPU with CTAs, up to a constant factor (usually 4x the resident occupancy)

				// Policy for upsweep kernel.
				// 		Reduces/counts all the different digit numerals for a given digit-place
				//
				(KEY_BITS > 4) ?			// UPSWEEP_CTA_OCCUPANCY			The targeted SM occupancy to feed PTXAS in order to influence how it does register allocation
					3 :							// 5bit
					6,							// 4bit
				7,							// UPSWEEP_LOG_THREADS				The number of threads (log) to launch per CTA.  Valid range: 5-10
				0,							// UPSWEEP_LOG_LOAD_VEC_SIZE		The vector-load size (log) for each load (log).  Valid range: 0-2
				2,							// UPSWEEP_LOG_LOADS_PER_TILE		The number of loads (log) per tile.  Valid range: 0-2

				// Spine-scan kernel policy
				//		Prefix sum of upsweep histograms counted by each CTA.  Relatively insignificant in the grand scheme, not really worth tuning for large problems)
				//
				8,							// SPINE_LOG_THREADS				The number of threads (log) to launch per CTA.  Valid range: 5-10
				2,							// SPINE_LOG_LOAD_VEC_SIZE			The vector-load size (log) for each load (log).  Valid range: 0-2
				0,							// SPINE_LOG_LOADS_PER_TILE			The number of loads (log) per tile.  Valid range: 0-2
				5,							// SPINE_LOG_RAKING_THREADS			The number of raking threads (log) for local prefix sum.  Valid range: 5-SPINE_LOG_THREADS

				// Policy for downsweep kernel
				//		Given prefix counts, scans/scatters keys into appropriate bins
				// 		Note: a "cycle" is a tile sub-segment up to 256 keys
				//
				b40c::partition::downsweep::SCATTER_TWO_PHASE,			// DOWNSWEEP_TWO_PHASE_SCATTER		Whether or not to perform a two-phase scatter (scatter to smem first to recover some locality before scattering to global bins)
				ProblemType::KEYS_ONLY ?		// DOWNSWEEP_CTA_OCCUPANCY			The targeted SM occupancy to feed PTXAS in order to influence how it does register allocation
					3 :
					2,
				ProblemType::KEYS_ONLY ?		// DOWNSWEEP_LOG_THREADS			The number of threads (log) to launch per CTA.  Valid range: 5-10, subject to constraints described above
					6 :
					6,
				ProblemType::KEYS_ONLY ?		// DOWNSWEEP_LOG_LOAD_VEC_SIZE		The vector-load size (log) for each load (log).  Valid range: 0-2, subject to constraints described above
					4 :
					4,
				0,								// DOWNSWEEP_LOG_LOADS_PER_TILE		The number of loads (log) per tile.  Valid range: 0-2
				ProblemType::KEYS_ONLY ?		// DOWNSWEEP_LOG_RAKING_THREADS		The number of raking threads (log) for local prefix sum.  Valid range: 5-DOWNSWEEP_LOG_THREADS
					6 :
					6>
			Policy;
	};

};


/**
 * SM11
 */
template <>
struct SortingPolicy<110> : ProblemType
{
	template <int BITS, int DUMMY = 0>
	struct BitPolicy
	{
		enum
		{
			KEY_BITS = CUB_MIN(BITS, 5)
		};

		typedef b40c::radix_sort::Policy<
				ProblemType,				// Problem type

				// Common
				110,						// SM ARCH
				KEY_BITS,					// RADIX_BITS

				// Launch tuning policy
				10,							// LOG_SCHEDULE_GRANULARITY			The "grain" by which to divide up the problem input.  E.g., 7 implies a near-even distribution of 128-key chunks to each CTA.  Related to, but different from the upsweep/downswep tile sizes, which may be different from each other.
				b40c::util::io::ld::NONE,	// CACHE_MODIFIER					Load cache-modifier.  Valid values: NONE, ca, cg, cs
				b40c::util::io::st::NONE,	// CACHE_MODIFIER					Store cache-modifier.  Valid values: NONE, wb, cg, cs
				false,						// EARLY_EXIT						Whether or not to early-terminate a sorting pass if we detect all keys have the same digit in that pass's digit place
				false,						// UNIFORM_SMEM_ALLOCATION			Whether or not to pad the dynamic smem allocation to ensure that all three kernels (upsweep, spine, downsweep) have the same overall smem allocation
				true, 						// UNIFORM_GRID_SIZE				Whether or not to launch the spine kernel with one CTA (all that's needed), or pad it up to the same grid size as the upsweep/downsweep kernels
				true,						// OVERSUBSCRIBED_GRID_SIZE			Whether or not to oversubscribe the GPU with CTAs, up to a constant factor (usually 4x the resident occupancy)

				// Policy for upsweep kernel.
				// 		Reduces/counts all the different digit numerals for a given digit-place
				//
				(KEY_BITS > 4) ?			// UPSWEEP_CTA_OCCUPANCY			The targeted SM occupancy to feed PTXAS in order to influence how it does register allocation
					2 :							// 5bit
					2,							// 4bit
				7,							// UPSWEEP_LOG_THREADS				The number of threads (log) to launch per CTA.  Valid range: 5-10
				0,							// UPSWEEP_LOG_LOAD_VEC_SIZE		The vector-load size (log) for each load (log).  Valid range: 0-2
				0,							// UPSWEEP_LOG_LOADS_PER_TILE		The number of loads (log) per tile.  Valid range: 0-2

				// Spine-scan kernel policy
				//		Prefix sum of upsweep histograms counted by each CTA.  Relatively insignificant in the grand scheme, not really worth tuning for large problems)
				//
				7,							// SPINE_LOG_THREADS				The number of threads (log) to launch per CTA.  Valid range: 5-10
				2,							// SPINE_LOG_LOAD_VEC_SIZE			The vector-load size (log) for each load (log).  Valid range: 0-2
				0,							// SPINE_LOG_LOADS_PER_TILE			The number of loads (log) per tile.  Valid range: 0-2
				5,							// SPINE_LOG_RAKING_THREADS			The number of raking threads (log) for local prefix sum.  Valid range: 5-SPINE_LOG_THREADS

				// Policy for downsweep kernel
				//		Given prefix counts, scans/scatters keys into appropriate bins
				// 		Note: a "cycle" is a tile sub-segment up to 256 keys
				//
				b40c::partition::downsweep::SCATTER_TWO_PHASE,			// DOWNSWEEP_TWO_PHASE_SCATTER		Whether or not to perform a two-phase scatter (scatter to smem first to recover some locality before scattering to global bins)
				ProblemType::KEYS_ONLY ?		// DOWNSWEEP_CTA_OCCUPANCY			The targeted SM occupancy to feed PTXAS in order to influence how it does register allocation
					2 :
					2,
				ProblemType::KEYS_ONLY ?		// DOWNSWEEP_LOG_THREADS			The number of threads (log) to launch per CTA.  Valid range: 5-10, subject to constraints described above
					6 :
					6,
				ProblemType::KEYS_ONLY ?		// DOWNSWEEP_LOG_LOAD_VEC_SIZE		The vector-load size (log) for each load (log).  Valid range: 0-2, subject to constraints described above
					4 :
					4,
				0,								// DOWNSWEEP_LOG_LOADS_PER_TILE		The number of loads (log) per tile.  Valid range: 0-2
				ProblemType::KEYS_ONLY ?		// DOWNSWEEP_LOG_RAKING_THREADS		The number of raking threads (log) for local prefix sum.  Valid range: 5-DOWNSWEEP_LOG_THREADS
					6 :
					6>
			Policy;
	};

};





/******************************************************************************
 * Main
 ******************************************************************************/

int main(int argc, char** argv)
{
	typedef SortingPolicy<200> 						Policy;

    typedef typename ProblemType::OriginalKeyType 	KeyType;
    typedef typename Policy::ValueType 				ValueType;
    typedef typename Policy::SizeT 					SizeT;

    const int KEY_BITS 								= sizeof(KeyType) * 8;

    // Initialize command line
    b40c::CommandLineArgs args(argc, argv);
    b40c::DeviceInit(args);

	// Usage/help
    if (args.CheckCmdLineFlag("help") || args.CheckCmdLineFlag("h")) {
    	printf("\nlars_demo [--device=<device index>] [--v] [--n=<elements>] "
    			"[--max-ctas=<max-thread-blocks>] [--i=<iterations>] "
    			"[--zeros | --regular] [--entropy-reduction=<random &'ing rounds>\n");
    	return 0;
    }

    // Parse commandline args
    SizeT 			num_elements = 1024 * 1024 * 8;			// 8 million pairs
    unsigned int 	max_ctas = 0;							// default: let the enactor decide how many CTAs to launch based upon device properties
    int 			iterations = 0;
    int				entropy_reduction = 0;
    int 			effective_bits = KEY_BITS;

    bool verbose = args.CheckCmdLineFlag("v");
    bool zeros = args.CheckCmdLineFlag("zeros");
    bool regular = args.CheckCmdLineFlag("regular");
    bool schmoo = args.CheckCmdLineFlag("schmoo");
    args.GetCmdLineArgument("n", num_elements);
    args.GetCmdLineArgument("i", iterations);
    args.GetCmdLineArgument("max-ctas", max_ctas);
    args.GetCmdLineArgument("entropy-reduction", entropy_reduction);
    args.GetCmdLineArgument("bits", effective_bits);

    if (zeros) printf("Zeros\n");
    else if (regular) printf("%d-bit mod-%llu\n", KEY_BITS, 1ull << effective_bits);
    else printf("%d-bit random\n", KEY_BITS);
    fflush(stdout);

	// Allocate and initialize host problem data and host reference solution
	KeyType *h_keys 				= new KeyType[num_elements];
	KeyType *h_reference_keys 		= new KeyType[num_elements];

	// Only use RADIX_BITS effective bits (remaining high order bits
	// are left zero): we only want to perform one sorting pass
	if (verbose) printf("Original: ");

	for (size_t i = 0; i < num_elements; ++i) {

		if (regular) {
			h_keys[i] = i & ((1ull << effective_bits) - 1);
		} else if (zeros) {
			h_keys[i] = 0;
		} else {
			b40c::util::RandomBits(h_keys[i], entropy_reduction, KEY_BITS);
		}

		h_reference_keys[i] = h_keys[i];

		if (verbose) {
			printf("%d, ", h_keys[i]);
			if ((i & 255) == 255) printf("\n\n");
		}

	}
	if (verbose) printf("\n");

    // Compute reference solution
	std::sort(h_reference_keys, h_reference_keys + num_elements);

	// Allocate device data. (We will let the sorting enactor create
	// the "pong" storage if/when necessary.)
	KeyType *d_keys;
	ValueType *d_values;
	cudaMalloc((void**) &d_keys, sizeof(KeyType) * num_elements);
	cudaMalloc((void**) &d_values, sizeof(ValueType) * num_elements);

	// Create a scan enactor
	b40c::radix_sort::Enactor enactor;
	enactor.ENACTOR_DEBUG = true;

	// Create ping-pong storage wrapper.
	b40c::util::PingPongStorage<KeyType, ValueType> sort_storage(d_keys, d_values);

	//
	// Perform one sorting pass (starting at bit zero and covering RADIX_BITS bits)
	//

	cudaMemcpy(
		sort_storage.d_keys[sort_storage.selector],
		h_keys,
		sizeof(KeyType) * num_elements,
		cudaMemcpyHostToDevice);

	printf("Incoming selector: %d\n", sort_storage.selector);

	// Sort
	enactor.Sort<
		0,
		KEY_BITS,
		Policy>(sort_storage, num_elements, max_ctas);

	printf("Outgoing selector: %d\n", sort_storage.selector);

	if (ProblemType::KEYS_ONLY) {
		printf("Restricted-range keys-only sort: ");
	} else {
		printf("Restricted-range key-value sort: ");
	}
	fflush(stdout);
	b40c::CompareDeviceResults(
		h_reference_keys,
		sort_storage.d_keys[sort_storage.selector],
		num_elements,
		true,
		verbose); printf("\n");

	enactor.ENACTOR_DEBUG = false;
	cudaThreadSynchronize();

	if (schmoo) {
		printf("iteration, elements, elapsed (ms), throughput (MKeys/s)\n");
	}

	b40c::GpuTimer gpu_timer;
	double max_exponent 		= log2(double(num_elements)) - 5.0;
	unsigned int max_int 		= (unsigned int) -1;
	float elapsed 				= 0;

	for (int i = 0; i < iterations; i++) {

		// Reset problem
		sort_storage.selector = 0;
		cudaMemcpy(
			sort_storage.d_keys[sort_storage.selector],
			h_keys,
			sizeof(KeyType) * num_elements,
			cudaMemcpyHostToDevice);

		if (schmoo) {

			// Sample a problem size
			unsigned int sample;
			b40c::util::RandomBits(sample);
			double scale = double(sample) / max_int;
			SizeT elements = (i < iterations / 2) ?
				(SizeT) pow(2.0, (max_exponent * scale) + 5.0) :		// log bias
				elements = scale * num_elements;						// uniform bias

			gpu_timer.Start();
			enactor.Sort<
				0,
				KEY_BITS,
				Policy>(sort_storage, elements, max_ctas);
			gpu_timer.Stop();

			float millis = gpu_timer.ElapsedMillis();
			printf("%d, %d, %.3f, %.2f\n",
				i,
				elements,
				millis,
				float(elements) / millis / 1000.f);
			fflush(stdout);

		} else {

			// Regular iteration
			gpu_timer.Start();
			enactor.Sort<
				0,
				KEY_BITS,
				Policy>(sort_storage, num_elements, max_ctas);
			gpu_timer.Stop();

			elapsed += gpu_timer.ElapsedMillis();
		}
	}

	// Display output
	if ((!schmoo) && (iterations > 0)) {
		float avg_elapsed = elapsed / float(iterations);
		printf("Elapsed millis: %f, avg elapsed: %f, throughput: %.2f Mkeys/s\n",
			elapsed,
			avg_elapsed,
			float(num_elements) / avg_elapsed / 1000.f);
	}

	// Cleanup any "pong" storage allocated by the enactor
	if (sort_storage.d_keys[1]) cudaFree(sort_storage.d_keys[1]);
	if (sort_storage.d_values[1]) cudaFree(sort_storage.d_values[1]);

	// Cleanup other
	delete h_keys;
	delete h_reference_keys;

	return 0;
}

