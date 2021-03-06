//
//  ViewController.m
//  HelloTensorFlow
//
//  Created by Jeff Tang on 1/4/18.
//  Copyright © 2018 Jeff Tang. All rights reserved.
//

#import "ViewController.h"

#include <fstream>
#include <queue>
#include "tensorflow/core/framework/op_kernel.h"
#include "tensorflow/core/public/session.h"
#include "ios_image_load.h"

NSString* RunInferenceOnImage(int wanted_width, int wanted_height, std::string input_layer, NSString *model);

@interface ViewController ()

@end

@implementation ViewController
-(void) showResult:(NSString *)result {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Inference Result" message:result preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction* action = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:action];
    [self presentViewController:alert animated:YES completion:nil];
}
-(void)tapped:(UITapGestureRecognizer *)tapGestureRecognizer {
    
    UIAlertAction* inceptionV3 = [UIAlertAction actionWithTitle:@"Inception v3 Retrained Model" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            NSString *result = RunInferenceOnImage(299, 299, "Mul", @"quantized_stripped_dogs_retrained");
            [self showResult:result];
    }];
    UIAlertAction* mobileNet = [UIAlertAction actionWithTitle:@"MobileNet 1.0 Retrained Model" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            NSString *result = RunInferenceOnImage(224, 224, "input", @"dog_retrained_mobilenet10_224_not_quantized");
            [self showResult:result];
    }];

    UIAlertAction* none = [UIAlertAction actionWithTitle:@"None" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction * action) {}];

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Pick a Model" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:inceptionV3];
    [alert addAction:mobileNet];
    [alert addAction:none];
    [self presentViewController:alert animated:YES completion:nil];
    
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    UILabel *lbl = [[UILabel alloc] init];
    [lbl setTranslatesAutoresizingMaskIntoConstraints:NO];
    lbl.text = @"Tap Anywhere";
    [self.view addSubview:lbl];
    
    //NSArray *horizontal = [NSLayoutConstraint constraintsWithVisualFormat:@"|-20-[view]-20-|" options:0 metrics:nil views:@{@"view" : lbl}];
    //NSArray *vertical = [NSLayoutConstraint constraintsWithVisualFormat:@"V:|-200-[view(50)]" options:0 metrics:nil views:@{@"view" : lbl}];
    
    NSLayoutConstraint *horizontal = [NSLayoutConstraint constraintWithItem:lbl
                                     attribute:NSLayoutAttributeCenterX
                                     relatedBy:NSLayoutRelationEqual
                                     toItem:self.view
                                     attribute:NSLayoutAttributeCenterX
                                     multiplier:1
                                     constant:0];
    NSLayoutConstraint *vertical = [NSLayoutConstraint constraintWithItem:lbl
                                     attribute:NSLayoutAttributeCenterY
                                     relatedBy:NSLayoutRelationEqual
                                     toItem:self.view
                                     attribute:NSLayoutAttributeCenterY
                                     multiplier:1
                                     constant:0];
    [self.view addConstraint:horizontal];
    [self.view addConstraint:vertical];

    UITapGestureRecognizer *recognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    [self.view addGestureRecognizer:recognizer];
    

}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end



namespace {
    class IfstreamInputStream : public ::google::protobuf::io::CopyingInputStream {
    public:
        explicit IfstreamInputStream(const std::string& file_name)
        : ifs_(file_name.c_str(), std::ios::in | std::ios::binary) {}
        ~IfstreamInputStream() { ifs_.close(); }
        
        int Read(void* buffer, int size) {
            if (!ifs_) {
                return -1;
            }
            ifs_.read(static_cast<char*>(buffer), size);
            return (int)ifs_.gcount();
        }
        
    private:
        std::ifstream ifs_;
    };
}  // namespace



// Returns the top N confidence values over threshold in the provided vector,
// sorted by confidence in descending order.
static void GetTopN(
                    const Eigen::TensorMap<Eigen::Tensor<float, 1, Eigen::RowMajor>,
                    Eigen::Aligned>& prediction,
                    const int num_results, const float threshold,
                    std::vector<std::pair<float, int> >* top_results) {
    // Will contain top N results in ascending order.
    std::priority_queue<std::pair<float, int>,
    std::vector<std::pair<float, int> >,
    std::greater<std::pair<float, int> > > top_result_pq;
    
    const long count = prediction.size();
    for (int i = 0; i < count; ++i) {
        const float value = prediction(i);
        
        // Only add it if it beats the threshold and has a chance at being in
        // the top N.
        if (value < threshold) {
            continue;
        }
        
        top_result_pq.push(std::pair<float, int>(value, i));
        
        // If at capacity, kick the smallest value out.
        if (top_result_pq.size() > num_results) {
            top_result_pq.pop();
        }
    }
    
    // Copy to output vector and reverse into descending order.
    while (!top_result_pq.empty()) {
        top_results->push_back(top_result_pq.top());
        top_result_pq.pop();
    }
    std::reverse(top_results->begin(), top_results->end());
}


bool PortableReadFileToProto(const std::string& file_name,
                             ::google::protobuf::MessageLite* proto) {
    ::google::protobuf::io::CopyingInputStreamAdaptor stream(
                                                             new IfstreamInputStream(file_name));
    stream.SetOwnsCopyingStream(true);
    // TODO(jiayq): the following coded stream is for debugging purposes to allow
    // one to parse arbitrarily large messages for MessageLite. One most likely
    // doesn't want to put protobufs larger than 64MB on Android, so we should
    // eventually remove this and quit loud when a large protobuf is passed in.
    ::google::protobuf::io::CodedInputStream coded_stream(&stream);
    // Total bytes hard limit / warning limit are set to 1GB and 512MB
    // respectively.
    coded_stream.SetTotalBytesLimit(1024LL << 20, 512LL << 20);
    return proto->ParseFromCodedStream(&coded_stream);
}

NSString* FilePathForResourceName(NSString* name, NSString* extension) {
    NSString* file_path = [[NSBundle mainBundle] pathForResource:name ofType:extension];
    if (file_path == NULL) {
        LOG(FATAL) << "Couldn't find '" << [name UTF8String] << "."
        << [extension UTF8String] << "' in bundle.";
    }
    return file_path;
}

NSString* RunInferenceOnImage(int wanted_width, int wanted_height, std::string input_layer, NSString *model) {
    tensorflow::SessionOptions options;
    
    tensorflow::Session* session_pointer = nullptr;
    tensorflow::Status session_status = tensorflow::NewSession(options, &session_pointer);
    if (!session_status.ok()) {
        std::string status_string = session_status.ToString();
        return [NSString stringWithFormat: @"Session create failed - %s",
                status_string.c_str()];
    }
    std::unique_ptr<tensorflow::Session> session(session_pointer);
    LOG(INFO) << "Session created.";
    
    tensorflow::GraphDef tensorflow_graph;
    LOG(INFO) << "Graph created.";
    
    
    //NSString* network_path = FilePathForResourceName(@"quantized_stripped_dogs_retrained", @"pb");
    //NSString* network_path = FilePathForResourceName(@"dog_retrained_mobilenet10_224_quantized", @"pb");
    //NSString* network_path = FilePathForResourceName(@"dog_retrained_mobilenet10_224_not_quantized", @"pb");
    NSString* network_path = FilePathForResourceName(model, @"pb");
    
    PortableReadFileToProto([network_path UTF8String], &tensorflow_graph);
    
    LOG(INFO) << "Creating session.";
    tensorflow::Status s = session->Create(tensorflow_graph);
    if (!s.ok()) {
        LOG(ERROR) << "Could not create TensorFlow Graph: " << s;
        return @"";
    }
    
    // Read the label list
    NSString* labels_path = FilePathForResourceName(@"dog_retrained_labels", @"txt");
    std::vector<std::string> label_strings;
    std::ifstream t;
    t.open([labels_path UTF8String]);
    std::string line;
    while(t){
        std::getline(t, line);
        label_strings.push_back(line);
    }
    t.close();
    
    //NSString* image_path = FilePathForResourceName(@"pug1", @"jpg");
    NSString* image_path = FilePathForResourceName(@"lab1", @"jpg");
    int image_width;
    int image_height;
    int image_channels;
    std::vector<tensorflow::uint8> image_data = LoadImageFromFile([image_path UTF8String], &image_width, &image_height, &image_channels);
    
//    const int wanted_width = 224; // 299
//    const int wanted_height = 224; // 299
    const int wanted_channels = 3;
    const float input_mean = 128.0f;
    const float input_std = 128.0f;
    
    assert(image_channels >= wanted_channels);
    tensorflow::Tensor image_tensor(
                                    tensorflow::DT_FLOAT,
                                    tensorflow::TensorShape({
        1, wanted_height, wanted_width, wanted_channels}));
    auto image_tensor_mapped = image_tensor.tensor<float, 4>();
    tensorflow::uint8* in = image_data.data();
    // tensorflow::uint8* in_end = (in + (image_height * image_width * image_channels));
    float* out = image_tensor_mapped.data();
    for (int y = 0; y < wanted_height; ++y) {
        const int in_y = (y * image_height) / wanted_height;
        tensorflow::uint8* in_row = in + (in_y * image_width * image_channels);
        float* out_row = out + (y * wanted_width * wanted_channels);
        for (int x = 0; x < wanted_width; ++x) {
            const int in_x = (x * image_width) / wanted_width;
            tensorflow::uint8* in_pixel = in_row + (in_x * image_channels);
            float* out_pixel = out_row + (x * wanted_channels);
            for (int c = 0; c < wanted_channels; ++c) {
                out_pixel[c] = (in_pixel[c] - input_mean) / input_std;
            }
        }
    }
    
    NSString* result = [network_path stringByAppendingString: @" - loaded!"];

    //std::string input_layer = "input"; // "Mul"
    std::string output_layer = "final_result";
    //    std::string output_layer = "output";
    std::vector<tensorflow::Tensor> outputs;
    tensorflow::Status run_status = session->Run({{input_layer, image_tensor}},
                                                 {output_layer}, {}, &outputs);
    if (!run_status.ok()) {
        LOG(ERROR) << "Running model failed: " << run_status;
        tensorflow::LogAllRegisteredKernels();
        result = @"Error running model";
        return result;
    }
    tensorflow::string status_string = run_status.ToString();
    result = [NSString stringWithFormat: @"%@ - %s\n", result,
              status_string.c_str()];
    
    tensorflow::Tensor* output = &outputs[0];
    const int kNumResults = 5;
    const float kThreshold = 0.01f;
    std::vector<std::pair<float, int> > top_results;
    GetTopN(output->flat<float>(), kNumResults, kThreshold, &top_results);
    
    std::stringstream ss;
    ss.precision(3);
    for (const auto& result : top_results) {
        const float confidence = result.first;
        const int index = result.second;
        
        ss << index << " " << confidence << "  ";
        
        // Write out the result as a string
        if (index < label_strings.size()) {
            // just for safety: theoretically, the output is under 1000 unless there
            // is some numerical issues leading to a wrong prediction.
            ss << label_strings[index];
        } else {
            ss << "Prediction: " << index;
        }
        
        ss << "\n";
    }
    
    LOG(INFO) << "Predictions: " << ss.str();
    
    tensorflow::string predictions = ss.str();
    result = [NSString stringWithFormat: @"%@ %s", result,
              predictions.c_str()];
    
    return result;
}

